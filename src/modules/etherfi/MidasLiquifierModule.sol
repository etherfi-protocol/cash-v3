// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiDataProvider } from "../../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IMidasVault } from "../../interfaces/IMidasVault.sol";
import { IPriceProvider } from "../../interfaces/IPriceProvider.sol";
import { Constants } from "../../utils/Constants.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";
import { ModuleLendGatewaySandwich } from "../ModuleLendGatewaySandwich.sol";

/**
 * @title MidasLiquifierModule
 * @notice Repays a safe's debt out of this contract's float and takes the matching value of a Midas vault token
 *         from the safe. Each payment token maps to exactly one debt token and one Midas redemption vault; the
 *         accumulated vault tokens are redeemed back into the debt token through that vault.
 * @dev Dual-engine: a gateway safe's debt is repaid on Aave through the lend gateway (the float hops through the
 *      safe, since the gateway pulls repayment from it), a legacy safe's on the DebtManager.
 */
contract MidasLiquifierModule is Constants, UpgradeableProxy, ModuleCheckBalance, ModuleLendGatewaySandwich {
    using SafeERC20 for IERC20;

    struct Pair {
        address debtToken;
        address redemptionVault;
        uint16 feeBps;
        uint128 flatFee;
    }

    /// @custom:storage-location erc7201:etherfi.storage.MidasLiquifierModule
    struct MidasLiquifierStorage {
        mapping(address paymentToken => Pair pair) pairs;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.MidasLiquifierModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MidasLiquifierStorageLocation = 0x9e66bed9ef45bbe314f5e472d1bf31a142c4fe68cd7edffafa0ecddb7db95a00;

    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");
    bytes32 public constant SETTLEMENT_DISPATCHER_BRIDGER_ROLE = keccak256("SETTLEMENT_DISPATCHER_BRIDGER_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Upper bound for a pair's fee, 10%
    uint16 public constant MAX_FEE_BPS = 1000;

    IDebtManager public immutable debtManager;
    IEtherFiDataProvider public immutable etherFiDataProvider;

    event PairSet(address indexed paymentToken, address indexed debtToken, address indexed redemptionVault, uint16 feeBps, uint128 flatFee);
    event PairRemoved(address indexed paymentToken);
    event Repaid(address indexed user, address indexed paymentToken, address indexed debtToken, uint256 debtRepaid, uint256 paymentAmount, uint256 feeAmount);
    event MidasRedeemRequested(address indexed paymentToken, address indexed assetOut, uint256 amount);
    event FundsWithdrawn(address indexed token, uint256 amount, address indexed recipient);

    error OnlyEtherFiSafe();
    error OnlyEtherFiWallet();
    error OnlySettlementDispatcherBridger();
    error PairNotSet();
    error InvalidValue();
    error FeeTooHigh();
    error AmountZero();
    error PaymentAmountZero();
    error InsufficientFloat();
    error InvalidConversion();
    error CannotWithdrawZeroAmount();
    error WithdrawFundsFailed();

    constructor(address _debtManager, address _etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        debtManager = IDebtManager(_debtManager);
        etherFiDataProvider = IEtherFiDataProvider(_etherFiDataProvider);
        _disableInitializers();
    }

    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    /**
     * @notice Registers or updates the debt token, redemption vault and fee for a payment token
     * @param paymentToken Midas vault token taken from the safe
     * @param debtToken Token whose debt the payment settles; must be the vault's redemption asset
     * @param redemptionVault Midas redemption vault for paymentToken
     * @param feeBps Proportional fee in basis points of the payment amount, kept by this contract
     * @param flatFee Flat fee per repayment in debt token units, charged in payment token at the same price
     */
    function setPair(address paymentToken, address debtToken, address redemptionVault, uint16 feeBps, uint128 flatFee) external onlyRoleRegistryOwner {
        if (paymentToken == address(0) || debtToken == address(0) || redemptionVault == address(0)) revert InvalidValue();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        _getMidasLiquifierStorage().pairs[paymentToken] = Pair(debtToken, redemptionVault, feeBps, flatFee);
        emit PairSet(paymentToken, debtToken, redemptionVault, feeBps, flatFee);
    }

    function removePair(address paymentToken) external onlyRoleRegistryOwner {
        delete _getMidasLiquifierStorage().pairs[paymentToken];
        emit PairRemoved(paymentToken);
    }

    function pairs(address paymentToken) external view returns (Pair memory) {
        return _getMidasLiquifierStorage().pairs[paymentToken];
    }

    /**
     * @notice Repays the user's debt in the pair's debt token and takes the equivalent payment token plus fee
     * @param user Address of the EtherFi Safe
     * @param paymentToken Midas vault token to take from the safe
     * @param debtAmount Amount of debt token to repay; capped at the outstanding debt
     */
    function repay(address user, address paymentToken, uint256 debtAmount) external nonReentrant whenNotPaused onlyEtherFiSafe(user) onlyEtherFiWallet {
        if (debtAmount == 0) revert AmountZero();
        Pair memory pair = _getPair(paymentToken);
        uint256 healthFactorBefore = _gatewayHealthFactor(user);

        // Pay the debt from the float first, then price what was actually repaid into the payment token
        uint256 debtRepaid = _repayDebt(user, IERC20(pair.debtToken), debtAmount);
        uint256 paymentAmount = convertDebtToPayment(paymentToken, debtRepaid);
        if (paymentAmount == 0) revert PaymentAmountZero();
        // Proportional fee on the payment plus the flat fee, both kept by this contract in payment token
        uint256 feeAmount = (paymentAmount * pair.feeBps) / BPS_DENOMINATOR + convertDebtToPayment(paymentToken, pair.flatFee);

        // Take payment plus fee out of the safe
        _reclaim(user, paymentToken, paymentAmount + feeAmount);
        // At zero fee the collateral taken matches the debt repaid, so health cannot worsen and de-risking is
        // never blocked. A fee takes more collateral than debt, so the end state must clear the gateway floor.
        if (feeAmount > 0) _ensureGatewayFloor(user, healthFactorBefore);

        emit Repaid(user, paymentToken, pair.debtToken, debtRepaid, paymentAmount, feeAmount);
    }

    function _repayDebt(address user, IERC20 debtToken, uint256 debtAmount) internal returns (uint256) {
        if (cashModule.usesLendGateway(user)) {
            // Cap at the user's Aave debt: the gateway refunds any unconsumed repayment to the safe, and an
            // uncapped transfer would strand the float there.
            uint256 debt = gateway().debtOf(user, address(debtToken));
            if (debtAmount > debt) debtAmount = debt;
            if (debtAmount == 0) revert AmountZero();
            if (debtToken.balanceOf(address(this)) < debtAmount) revert InsufficientFloat();

            // The gateway pulls repayment from the safe, so the float hops through it within this transaction.
            debtToken.safeTransfer(user, debtAmount);
            return gateway().repay(user, address(debtToken), debtAmount);
        }

        // Legacy safe: cap at the outstanding debt before checking the float, then let the DebtManager pull the
        // repayment from this contract with an approval for exactly this call
        uint256 legacyDebt = debtManager.borrowingOf(user, address(debtToken));
        if (debtAmount > legacyDebt) debtAmount = legacyDebt;
        if (debtAmount == 0) revert AmountZero();
        uint256 balanceBefore = debtToken.balanceOf(address(this));
        if (balanceBefore < debtAmount) revert InsufficientFloat();

        debtToken.forceApprove(address(debtManager), debtAmount);
        debtManager.repay(user, address(debtToken), debtAmount);
        debtToken.forceApprove(address(debtManager), 0);

        // The DebtManager caps at the outstanding debt, so measure what actually left the float
        uint256 debtRepaid = balanceBefore - debtToken.balanceOf(address(this));
        if (debtRepaid > debtAmount) revert InvalidConversion();
        return debtRepaid;
    }

    function _reclaim(address user, address paymentToken, uint256 amount) internal {
        // A gateway safe keeps its tokens supplied to Aave, so withdraw the part not already loose in the safe,
        // then require the full amount is there
        _pullAndRequire(user, paymentToken, amount);

        // Have the safe approve this contract for the amount, then pull it
        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        uint256[] memory values = new uint256[](1);
        to[0] = paymentToken;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, address(this), amount);
        IEtherFiSafe(user).execTransactionFromModule(to, values, data);

        IERC20(paymentToken).safeTransferFrom(user, address(this), amount);
    }

    /**
     * @notice Requests redemption of accumulated payment tokens into the pair's debt token
     * @dev Midas redemptions are approved off-chain; the debt token arrives at this contract later
     * @param paymentToken Midas vault token to redeem
     * @param amount Amount of payment token to redeem
     */
    function redeemMidas(address paymentToken, uint256 amount) external nonReentrant whenNotPaused {
        if (!roleRegistry().hasRole(SETTLEMENT_DISPATCHER_BRIDGER_ROLE, msg.sender)) revert OnlySettlementDispatcherBridger();
        if (amount == 0) revert AmountZero();
        Pair memory pair = _getPair(paymentToken);

        // Midas escrows the payment token now and sends the debt token here once its operator approves
        IERC20(paymentToken).forceApprove(pair.redemptionVault, amount);
        IMidasVault(pair.redemptionVault).redeemRequest(pair.debtToken, amount, address(this));

        emit MidasRedeemRequested(paymentToken, pair.debtToken, amount);
    }

    /**
     * @notice Withdraws tokens or ETH from the contract
     * @param amount Amount to withdraw, 0 for the full balance
     */
    function withdrawFunds(address token, address recipient, uint256 amount) external onlyRoleRegistryOwner {
        if (recipient == address(0)) revert InvalidValue();
        if (token == ETH) {
            if (amount == 0) amount = address(this).balance;
            if (amount == 0) revert CannotWithdrawZeroAmount();
            (bool success,) = payable(recipient).call{ value: amount }("");
            if (!success) revert WithdrawFundsFailed();
        } else {
            if (amount == 0) amount = IERC20(token).balanceOf(address(this));
            if (amount == 0) revert CannotWithdrawZeroAmount();
            IERC20(token).safeTransfer(recipient, amount);
        }
        emit FundsWithdrawn(token, amount, recipient);
    }

    /**
     * @notice Converts an amount of the pair's debt token into the payment token at PriceProvider prices, before fee
     */
    function convertDebtToPayment(address paymentToken, uint256 debtAmount) public view returns (uint256) {
        Pair memory pair = _getPair(paymentToken);
        IPriceProvider priceProvider = IPriceProvider(etherFiDataProvider.getPriceProvider());
        uint256 debtValue = debtAmount * priceProvider.price(pair.debtToken) * 10 ** IERC20Metadata(paymentToken).decimals();
        return debtValue / (priceProvider.price(paymentToken) * 10 ** IERC20Metadata(pair.debtToken).decimals());
    }

    /**
     * @notice Converts an amount of the payment token into the pair's debt token at PriceProvider prices
     */
    function convertPaymentToDebt(address paymentToken, uint256 paymentAmount) public view returns (uint256) {
        Pair memory pair = _getPair(paymentToken);
        IPriceProvider priceProvider = IPriceProvider(etherFiDataProvider.getPriceProvider());
        uint256 paymentValue = paymentAmount * priceProvider.price(paymentToken) * 10 ** IERC20Metadata(pair.debtToken).decimals();
        return paymentValue / (priceProvider.price(pair.debtToken) * 10 ** IERC20Metadata(paymentToken).decimals());
    }

    function _getPair(address paymentToken) internal view returns (Pair memory) {
        Pair memory pair = _getMidasLiquifierStorage().pairs[paymentToken];
        if (pair.debtToken == address(0)) revert PairNotSet();
        return pair;
    }

    function _getMidasLiquifierStorage() private pure returns (MidasLiquifierStorage storage $) {
        assembly {
            $.slot := MidasLiquifierStorageLocation
        }
    }

    modifier onlyEtherFiSafe(address account) {
        if (!etherFiDataProvider.isEtherFiSafe(account)) revert OnlyEtherFiSafe();
        _;
    }

    modifier onlyEtherFiWallet() {
        if (!roleRegistry().hasRole(ETHER_FI_WALLET_ROLE, msg.sender)) revert OnlyEtherFiWallet();
        _;
    }
}
