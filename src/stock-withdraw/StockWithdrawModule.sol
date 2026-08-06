// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import { IBridgeModule } from "../interfaces/IBridgeModule.sol";
import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { IOFT, MessagingFee, OFTReceipt, SendParam } from "../interfaces/IOFT.sol";
import { WithdrawalRequest } from "../interfaces/ICashModule.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";
import { ModuleCheckBalance } from "../modules/ModuleCheckBalance.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title StockWithdrawModule
 * @author ether.fi
 * @notice Cross-chain wrapped-stock withdrawal module installed on the OP `EtherFiSafe`. The
 *         user signs ONE intent at `requestWithdrawal` — `(iToken, amount, minReturn, deadline,
 *         recipient)` — which places a CashModule withdrawal hold (recipient = this module).
 *         After the withdrawal delay matures, the permissionless, payable
 *         `executeWithdrawal(safe)` processes the withdrawal (iTOKEN lands here) and OFT-sends
 *         it to the mainnet `StockUnwrapper` with a composeMsg carrying the order terms. On
 *         Ethereum the unwrapper redeems the Backed ERC-4626 wrapper to `recipient` (reverting
 *         if output < `minReturn`, which parks the LZ compose message for retry) or, past
 *         `deadline`, delivers the wrapped token to the user's deterministic TradingSafe.
 * @dev Funds route through the module (Stargate pattern) because the OFT send needs
 *      `msg.value` for the LayerZero fee, which the execute caller supplies — that cannot be
 *      injected into a safe-originated call. iTOKENs are ShadowOFTs (the OFT IS the token,
 *      mint/burn), so no residual approvals are left behind.
 *
 *      OFT `minAmountLD` only guards shared-decimal dust rounding (set from `quoteOFT`);
 *      economic slippage protection is exclusively `minReturn`, enforced against the actual
 *      redeem output on Ethereum.
 */
contract StockWithdrawModule is ModuleBase, ModuleCheckBalance, UpgradeableProxy, IBridgeModule {
    using MessageHashUtils for bytes32;
    using OptionsBuilder for bytes;
    using SafeERC20 for IERC20;

    /// @notice User-signed withdrawal intent. One per safe at a time.
    /// @dev `minReturn` is denominated in the UNDERLYING stock (e.g. SPYx), not the wrapper.
    ///      `deadline` is evaluated on Ethereum at lzCompose time (and gates execute here).
    struct Order {
        address iToken;
        uint256 amount;
        uint256 minReturn;
        uint256 deadline;
        address recipient;
    }

    /// @notice Everything `executeWithdrawal` needs, captured at `requestWithdrawal`.
    /// @dev `dstEid`/`unwrapper` are snapshotted at request (and bound into the signature) so
    ///      an admin config change cannot re-route a withdrawal the user already signed.
    struct StoredWithdrawal {
        Order order;
        bytes32 withdrawalId;
        uint32 dstEid;
        address unwrapper;
    }

    /// @custom:storage-location erc7201:etherfi.storage.StockWithdrawModule
    struct StockWithdrawModuleStorage {
        /// @notice Mapping of safe address to its single active stored withdrawal.
        mapping(address safe => StoredWithdrawal withdrawal) withdrawals;
        /// @notice Wrapped-stock ShadowOFTs (iTOKENs) this module may bridge.
        mapping(address iToken => bool supported) supportedTokens;
        /// @notice Ethereum mainnet endpoint ID.
        uint32 dstEid;
        /// @notice The mainnet `StockUnwrapper` composed receiver.
        address stockUnwrapper;
        /// @notice Executor gas limit for the destination lzCompose call.
        uint128 composeGasLimit;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.StockWithdrawModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StockWithdrawModuleStorageLocation = 0x79b068f9b079c00932ab348c89f00dce3855a0360decf75df1474e5e0fccf900;

    /// @notice Role allowed to configure supported tokens, destination and compose gas.
    bytes32 public constant STOCK_WITHDRAW_MODULE_ADMIN_ROLE = keccak256("STOCK_WITHDRAW_MODULE_ADMIN_ROLE");

    /// @dev Domain-separator-style prefixes for the digests the user signs.
    bytes32 private constant REQUEST_WITHDRAWAL_SIG = keccak256("StockWithdrawModule.requestWithdrawal");
    bytes32 private constant CANCEL_WITHDRAWAL_SIG = keccak256("StockWithdrawModule.cancelWithdrawal");

    event WithdrawalRequested(address indexed safe, bytes32 indexed withdrawalId, address iToken, uint256 amount, uint256 minReturn, uint256 deadline, address recipient);
    event WithdrawalExecuted(address indexed safe, bytes32 indexed withdrawalId, address iToken, uint256 amount, address recipient);
    event WithdrawalCancelled(address indexed safe, bytes32 indexed withdrawalId);
    event TokensConfigured(address[] iTokens, bool[] supported);
    event DestinationSet(uint32 dstEid, address stockUnwrapper);
    event ComposeGasLimitSet(uint128 oldGasLimit, uint128 newGasLimit);

    /// @notice Reverts when a non-admin calls an admin function.
    error OnlyAdmin();
    /// @notice Reverts when the iToken is not on the supported list.
    error TokenNotSupported();
    /// @notice Reverts when a supported iToken is not its own OFT (ShadowOFT invariant).
    error InvalidOFT();
    /// @notice Reverts when `requestWithdrawal` is called on a safe with an active order.
    error OrderAlreadyActive();
    /// @notice Reverts when execute/cancel finds no stored withdrawal.
    error NoActiveOrder();
    /// @notice Reverts when the user's signature doesn't meet the safe's threshold.
    error InvalidSignatures();
    /// @notice Reverts when `executeWithdrawal` runs after `order.deadline`.
    error OrderExpired();
    /// @notice Reverts when `cancelExpiredWithdrawal` runs at or before `order.deadline`.
    error OrderNotExpired();
    /// @notice Reverts when `msg.value` doesn't cover the quoted LayerZero native fee.
    error InsufficientNativeFee();
    /// @notice Reverts when refunding excess `msg.value` to the caller fails.
    error NativeTransferFailed();
    /// @notice Reverts when the pending CashModule withdrawal doesn't match the stored order.
    error CannotFindMatchingWithdrawal();
    /// @notice Reverts when destination config (dstEid / unwrapper / composeGas) is unset.
    error MissingConfig();
    /// @notice Reverts when CashModule would process the withdrawal immediately.
    error ZeroWithdrawalDelay();
    /// @notice Reverts when the order expires before the CashModule withdrawal delay elapses.
    error DeadlineBeforeWithdrawalDelay();

    /// @dev Immutables (`etherFiDataProvider`, `cashModule`) live in the IMPLEMENTATION's code —
    ///      every upgrade impl must be constructed with the same data provider.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        _disableInitializers();
    }

    /**
     * @notice Initialises the proxy.
     * @param _roleRegistry Role registry (upgrade authority + pause control + admin role).
     * @param _dstEid Ethereum mainnet endpoint ID.
     * @param _stockUnwrapper Mainnet StockUnwrapper; MAY be zero at deploy (chicken-and-egg
     *        with the mainnet deploy) and set later via `setDestination` — requests revert
     *        `MissingConfig` until it is set.
     * @param _composeGasLimit Executor gas for the destination lzCompose call.
     */
    function initialize(address _roleRegistry, uint32 _dstEid, address _stockUnwrapper, uint128 _composeGasLimit) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        if (_dstEid == 0 || _composeGasLimit == 0) revert InvalidInput();
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        $.dstEid = _dstEid;
        $.stockUnwrapper = _stockUnwrapper;
        $.composeGasLimit = _composeGasLimit;
    }

    // ---- Admin config ----

    /// @notice Registers/unregisters wrapped-stock ShadowOFTs. Enforces the ShadowOFT
    ///         invariant `IOFT(iToken).token() == iToken` on registration.
    function configureTokens(address[] calldata iTokens, bool[] calldata supported) external {
        _onlyAdmin();
        uint256 len = iTokens.length;
        if (len == 0 || len != supported.length) revert ArrayLengthMismatch();
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        for (uint256 i = 0; i < len;) {
            if (iTokens[i] == address(0)) revert InvalidInput();
            if (supported[i] && IOFT(iTokens[i]).token() != iTokens[i]) revert InvalidOFT();
            $.supportedTokens[iTokens[i]] = supported[i];
            unchecked {
                ++i;
            }
        }
        emit TokensConfigured(iTokens, supported);
    }

    /// @notice Sets the destination endpoint + unwrapper. Zero unwrapper disables new requests.
    function setDestination(uint32 _dstEid, address _stockUnwrapper) external {
        _onlyAdmin();
        if (_dstEid == 0) revert InvalidInput();
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        $.dstEid = _dstEid;
        $.stockUnwrapper = _stockUnwrapper;
        emit DestinationSet(_dstEid, _stockUnwrapper);
    }

    /// @notice Sets the executor gas limit for the destination lzCompose call. Read live at
    ///         execute time (not snapshotted) so admins can bump gas for stuck sends.
    function setComposeGasLimit(uint128 _composeGasLimit) external {
        _onlyAdmin();
        if (_composeGasLimit == 0) revert InvalidInput();
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        emit ComposeGasLimitSet($.composeGasLimit, _composeGasLimit);
        $.composeGasLimit = _composeGasLimit;
    }

    // ---- Views ----

    function getOrder(address safe) external view returns (Order memory) {
        return _getStockWithdrawModuleStorage().withdrawals[safe].order;
    }

    function getWithdrawal(address safe) external view returns (StoredWithdrawal memory) {
        return _getStockWithdrawModuleStorage().withdrawals[safe];
    }

    function isTokenSupported(address iToken) external view returns (bool) {
        return _getStockWithdrawModuleStorage().supportedTokens[iToken];
    }

    function getDstEid() external view returns (uint32) {
        return _getStockWithdrawModuleStorage().dstEid;
    }

    function getStockUnwrapper() external view returns (address) {
        return _getStockWithdrawModuleStorage().stockUnwrapper;
    }

    function getComposeGasLimit() external view returns (uint128) {
        return _getStockWithdrawModuleStorage().composeGasLimit;
    }

    /**
     * @notice Quotes the LayerZero native fee for the stored withdrawal.
     * @return feeToken Always `Constants.ETH`.
     * @return amount The native fee the `executeWithdrawal` caller must supply.
     */
    function getWithdrawalFee(address safe) external view returns (address feeToken, uint256 amount) {
        StoredWithdrawal memory withdrawal = _getStockWithdrawModuleStorage().withdrawals[safe];
        if (withdrawal.order.iToken == address(0)) revert NoActiveOrder();
        MessagingFee memory fee = IOFT(withdrawal.order.iToken).quoteSend(_buildSendParam(safe, withdrawal), false);
        return (ETH, fee.nativeFee);
    }

    // ---- Lifecycle ----

    /**
     * @notice Stores a user-signed withdrawal intent for `safe` and places a CashModule
     *         withdrawal hold with this module as recipient. CashModule sources the iTOKEN
     *         from the Aave lend gateway if it is currently supplied as collateral.
     * @dev One active withdrawal per safe. The signature binds the order AND the destination
     *      route snapshot (dstEid, unwrapper), so neither a keeper nor an admin config change
     *      can re-route funds the user didn't authorise.
     */
    function requestWithdrawal(address safe, Order calldata order, address[] calldata signers, bytes[] calldata signatures) external nonReentrant whenNotPaused onlyEtherFiSafe(safe) {
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        _validateRequest($, safe, order);

        uint256 nonce = IEtherFiSafe(safe).useNonce();
        if (!IEtherFiSafe(safe).checkSignatures(_requestDigest(safe, order, nonce), signers, signatures)) revert InvalidSignatures();

        bytes32 withdrawalId = keccak256(abi.encode(block.chainid, address(this), safe, nonce, order));
        $.withdrawals[safe] = StoredWithdrawal({ order: order, withdrawalId: withdrawalId, dstEid: $.dstEid, unwrapper: $.stockUnwrapper });

        emit WithdrawalRequested(safe, withdrawalId, order.iToken, order.amount, order.minReturn, order.deadline, order.recipient);

        cashModule.requestWithdrawalByModule(safe, order.iToken, order.amount);
    }

    /**
     * @notice Executes the stored withdrawal for `safe`: processes the matured CashModule
     *         withdrawal (iTOKEN lands in this module) and OFT-sends it to the mainnet
     *         unwrapper with the composed order terms.
     * @dev Permissionless and payable: any caller merely replays what the user signed and
     *      pays the LayerZero native fee (`getWithdrawalFee`); excess msg.value is refunded.
     *      CashModule enforces the withdrawal delay inside `processWithdrawal`.
     */
    function executeWithdrawal(address safe) external payable nonReentrant whenNotPaused onlyEtherFiSafe(safe) {
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        StoredWithdrawal memory withdrawal = $.withdrawals[safe];
        if (withdrawal.order.iToken == address(0)) revert NoActiveOrder();
        if (block.timestamp > withdrawal.order.deadline) revert OrderExpired();

        WithdrawalRequest memory pending = cashModule.getData(safe).pendingWithdrawalRequest;
        if (pending.recipient != address(this) || pending.tokens.length != 1 || pending.tokens[0] != withdrawal.order.iToken || pending.amounts[0] != withdrawal.order.amount) {
            revert CannotFindMatchingWithdrawal();
        }

        delete $.withdrawals[safe];
        cashModule.processWithdrawal(safe);

        _sendOft(safe, withdrawal);

        emit WithdrawalExecuted(safe, withdrawal.withdrawalId, withdrawal.order.iToken, withdrawal.order.amount, withdrawal.order.recipient);
    }

    /**
     * @notice Cancels the stored withdrawal for `safe`, releasing the CashModule hold.
     *         Signed by the safe's owners (same threshold as `requestWithdrawal`).
     * @dev `cancelWithdrawalByModule` calls back into `cancelBridgeByCashModule`, which
     *      clears state and emits.
     */
    function cancelWithdrawal(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        if ($.withdrawals[safe].order.iToken == address(0)) revert NoActiveOrder();

        bytes32 digest = keccak256(abi.encodePacked(CANCEL_WITHDRAWAL_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignatures();

        cashModule.cancelWithdrawalByModule(safe);
    }

    /**
     * @notice Permissionlessly cancels an EXPIRED stored withdrawal, releasing its CashModule
     *         hold WITHOUT an owner signature.
     * @dev Once `block.timestamp > order.deadline`, `executeWithdrawal` can never succeed
     *      again, so the hold would otherwise sit until an owner signs. Authorization is
     *      purely the elapsed deadline: this merely releases the safe's own funds back to the
     *      safe — no fund-movement authority to abuse.
     */
    function cancelExpiredWithdrawal(address safe) external nonReentrant onlyEtherFiSafe(safe) {
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        StoredWithdrawal memory withdrawal = $.withdrawals[safe];
        if (withdrawal.order.iToken == address(0)) revert NoActiveOrder();
        if (block.timestamp <= withdrawal.order.deadline) revert OrderNotExpired();

        cashModule.cancelWithdrawalByModule(safe);
    }

    /**
     * @notice Hook called by `CashModule.cancelWithdrawalByModule` to keep our state in sync.
     *         Clears the stored withdrawal and emits if one is still present. No-op if already
     *         cleared (`executeWithdrawal` deletes its own record before processing).
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != address(cashModule)) revert Unauthorized();
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        if ($.withdrawals[safe].order.iToken == address(0)) return;
        bytes32 withdrawalId = $.withdrawals[safe].withdrawalId;
        delete $.withdrawals[safe];
        emit WithdrawalCancelled(safe, withdrawalId);
    }

    /// @notice Accepts LayerZero fee refunds.
    receive() external payable { }

    // ---- Internals ----

    /// @dev Split out of `requestWithdrawal` to stay under the legacy stack limit.
    function _validateRequest(StockWithdrawModuleStorage storage $, address safe, Order calldata order) internal view {
        if (order.amount == 0 || order.recipient == address(0) || order.minReturn == 0 || order.deadline <= block.timestamp) revert InvalidInput();
        if (!$.supportedTokens[order.iToken]) revert TokenNotSupported();
        if ($.withdrawals[safe].order.iToken != address(0)) revert OrderAlreadyActive();
        if ($.dstEid == 0 || $.stockUnwrapper == address(0) || $.composeGasLimit == 0 || address(cashModule) == address(0)) revert MissingConfig();

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        if (withdrawalDelay == 0) revert ZeroWithdrawalDelay();
        if (order.deadline <= block.timestamp + withdrawalDelay) revert DeadlineBeforeWithdrawalDelay();
    }

    /// @dev Digest the safe owners sign: the order plus the destination route snapshot.
    function _requestDigest(address safe, Order calldata order, uint256 nonce) internal view returns (bytes32) {
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        return keccak256(abi.encodePacked(
            REQUEST_WITHDRAWAL_SIG,
            block.chainid,
            address(this),
            nonce,
            safe,
            abi.encode(order),
            $.dstEid,
            $.stockUnwrapper
        )).toEthSignedMessageHash();
    }

    /// @dev Builds the SendParam for the stored withdrawal. `minAmountLD` starts at the full
    ///      amount and is tightened to `quoteOFT`'s `amountReceivedLD` at send time (dust
    ///      rounding only — economic slippage is `minReturn`, enforced on Ethereum).
    function _buildSendParam(address safe, StoredWithdrawal memory withdrawal) internal view returns (SendParam memory) {
        return SendParam({
            dstEid: withdrawal.dstEid,
            to: bytes32(uint256(uint160(withdrawal.unwrapper))),
            amountLD: withdrawal.order.amount,
            minAmountLD: withdrawal.order.amount,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, _getStockWithdrawModuleStorage().composeGasLimit, 0),
            composeMsg: abi.encode(safe, withdrawal.order.recipient, withdrawal.order.minReturn, withdrawal.order.deadline),
            oftCmd: new bytes(0)
        });
    }

    /// @dev Quotes, pays and dispatches the OFT send from this module's balance. The caller
    ///      funds the LZ fee; excess is refunded to them (and they are the LZ refund address).
    function _sendOft(address safe, StoredWithdrawal memory withdrawal) internal {
        IOFT oft = IOFT(withdrawal.order.iToken);
        SendParam memory sendParam = _buildSendParam(safe, withdrawal);

        (,, OFTReceipt memory receipt) = oft.quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        MessagingFee memory fee = oft.quoteSend(sendParam, false);
        if (msg.value < fee.nativeFee) revert InsufficientNativeFee();

        if (oft.approvalRequired()) IERC20(oft.token()).forceApprove(address(oft), withdrawal.order.amount);
        oft.send{ value: fee.nativeFee }(sendParam, fee, payable(msg.sender));

        uint256 excess = msg.value - fee.nativeFee;
        if (excess > 0) {
            (bool success,) = payable(msg.sender).call{ value: excess }("");
            if (!success) revert NativeTransferFailed();
        }
    }

    function _onlyAdmin() internal view {
        if (!IRoleRegistry(etherFiDataProvider.roleRegistry()).hasRole(STOCK_WITHDRAW_MODULE_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
    }

    function _getStockWithdrawModuleStorage() internal pure returns (StockWithdrawModuleStorage storage $) {
        assembly {
            $.slot := StockWithdrawModuleStorageLocation
        }
    }
}
