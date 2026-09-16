// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { ILayerZeroTeller } from "../interfaces/ILayerZeroTeller.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { ITradingSafeFactory } from "../interfaces/ITradingSafeFactory.sol";
import { ITradingSafeLiquidDepositModule } from "../interfaces/ITradingSafeLiquidDepositModule.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";

/**
 * @title TradingSafeLiquidDepositModule
 * @author ether.fi
 * @notice Safe module on Ethereum mainnet that lets a TradingSafe's owners authorize an atomic
 *         deposit into a configured Liquid vault, with the freshly minted shares forwarded in the
 *         same transaction to the safe's factory-bound TopUp address. The existing TopUp rail then
 *         handles the configured destination-chain delivery.
 * @dev The recipient is never caller-chosen: it is resolved from the TradingSafeFactory as
 *      `getTopUpAddress(safe)` and bound into the owner-quorum digest, so a relayer cannot divert
 *      funds. The selected input and Liquid vault are also signature-bound. Only Liquid vaults
 *      whose teller has been validated and configured by governance can be selected, and only the
 *      exact minted delta is transferred, leaving pre-existing shares in the safe untouched.
 * @dev Moves tokens through the safe itself via `execTransactionFromModule`, so the module must be
 *      **enabled on the safe** (registered as a default module on the mainnet data provider, or
 *      added per-safe). The relayer is untrusted — the owner signatures authorize — so submission
 *      is permissionless. Replay protection is the safe nonce; a signed `deadline` stops a stashed
 *      signature from being replayed later.
 */
contract TradingSafeLiquidDepositModule is ITradingSafeLiquidDepositModule, ModuleBase, Pausable, ReentrancyGuard {
    using MessageHashUtils for bytes32;

    /// @notice Role allowed to add and remove Liquid vault routes.
    bytes32 public constant TRADING_SAFE_LIQUID_DEPOSIT_MODULE_ADMIN = keccak256("TRADING_SAFE_LIQUID_DEPOSIT_MODULE_ADMIN");

    /// @notice Configured teller for each Liquid vault share token.
    mapping(address liquidAsset => ILayerZeroTeller teller) public liquidAssetToTeller;

    /// @dev Domain-separator-style prefix for the digest the owners sign.
    bytes32 private constant DEPOSIT_SIG = keccak256("TradingSafeLiquidDepositModule.depositToTopUp");

    /**
     * @param _liquidAssets Liquid vault share tokens available at deployment.
     * @param _tellers Validated Veda tellers corresponding to `_liquidAssets`.
     * @param _dataProvider EtherFi data provider (resolves the safe factory and role registry).
     */
    constructor(address[] memory _liquidAssets, address[] memory _tellers, address _dataProvider) ModuleBase(_dataProvider) {
        _setLiquidAssets(_liquidAssets, _tellers);
    }

    function setupModule(bytes calldata) external override { }

    /// @inheritdoc ITradingSafeLiquidDepositModule
    function depositToTopUp(ITradingSafeLiquidDepositModule.DepositRequest calldata request, address[] calldata signers, bytes[] calldata signatures) external whenNotPaused nonReentrant onlyEtherFiSafe(request.safe) {
        if (request.assetToDeposit == address(0)) revert InvalidConfiguration();
        if (request.amountToDeposit == 0) revert InvalidAmount();
        if (request.minReturn == 0) revert InvalidMinReturn();
        if (block.timestamp > request.deadline) revert DepositExpired();

        ILayerZeroTeller teller = liquidAssetToTeller[request.liquidAsset];
        if (address(teller) == address(0)) revert UnsupportedLiquidAsset();

        address topUp = ITradingSafeFactory(etherFiDataProvider.getEtherFiSafeFactory()).getTopUpAddress(request.safe);
        if (topUp == address(0)) revert NoTopUpAddress();

        _verifySignatures(request.safe, topUp, keccak256(abi.encode(request)), signers, signatures);
        _checkTellerReady(teller, request.assetToDeposit);

        uint256 minted = _depositToLiquid(request.safe, request.assetToDeposit, request.liquidAsset, teller, request.amountToDeposit, request.minReturn);
        _forwardToTopUp(request.safe, topUp, request.liquidAsset, minted);

        emit DepositedToTopUp(request.safe, topUp, request.assetToDeposit, request.liquidAsset, request.amountToDeposit, minted);
    }

    /// @dev Rejects the deposit unless the teller currently accepts the input and applies no share lock.
    ///      A nonzero share lock would trap freshly minted shares in the safe and revert the
    ///      same-transaction forward, so failing early gives a precise error instead of an opaque one.
    function _checkTellerReady(ILayerZeroTeller teller, address assetToDeposit) private view {
        if (!teller.assetData(ERC20(assetToDeposit)).allowDeposits) revert DepositAssetNotAllowed();
        if (teller.shareLockPeriod() != 0) revert SharesLocked();
    }

    /// @dev Deposits exactly `amountToDeposit` through the configured teller and returns the exact
    ///      shares minted. The vault allowance is reset before and after use, and exact input debit
    ///      plus minimum output are asserted independently of token return values.
    function _depositToLiquid(address safe, address assetToDeposit, address liquidAsset, ILayerZeroTeller teller, uint256 amountToDeposit, uint256 minReturn) private returns (uint256 minted) {
        uint256 assetBefore = IERC20(assetToDeposit).balanceOf(safe);
        if (assetBefore < amountToDeposit) revert InsufficientBalance();
        uint256 liquidBefore = IERC20(liquidAsset).balanceOf(safe);

        address[] memory to = new address[](4);
        uint256[] memory values = new uint256[](4);
        bytes[] memory data = new bytes[](4);

        to[0] = assetToDeposit;
        data[0] = abi.encodeCall(IERC20.approve, (liquidAsset, 0));
        to[1] = assetToDeposit;
        data[1] = abi.encodeCall(IERC20.approve, (liquidAsset, amountToDeposit));
        to[2] = address(teller);
        data[2] = abi.encodeCall(ILayerZeroTeller.deposit, (ERC20(assetToDeposit), amountToDeposit, minReturn));
        to[3] = assetToDeposit;
        data[3] = abi.encodeCall(IERC20.approve, (liquidAsset, 0));

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        if (assetBefore - IERC20(assetToDeposit).balanceOf(safe) != amountToDeposit) {
            revert DepositTransferFailed();
        }

        minted = IERC20(liquidAsset).balanceOf(safe) - liquidBefore;
        if (minted < minReturn) revert InsufficientReturnAmount();
    }

    /// @dev Transfers exactly `minted` shares to `topUp`, asserting no newly minted shares linger
    ///      in the safe and that the TopUp receives the full amount.
    function _forwardToTopUp(address safe, address topUp, address liquidAsset, uint256 minted) private {
        uint256 safeBefore = IERC20(liquidAsset).balanceOf(safe);
        uint256 topUpBefore = IERC20(liquidAsset).balanceOf(topUp);

        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);

        to[0] = liquidAsset;
        data[0] = abi.encodeCall(IERC20.transfer, (topUp, minted));

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        if (safeBefore - IERC20(liquidAsset).balanceOf(safe) != minted) {
            revert DepositTransferFailed();
        }
        if (IERC20(liquidAsset).balanceOf(topUp) - topUpBefore != minted) {
            revert TopUpCreditFailed();
        }
    }

    /// @dev Verifies the owner quorum, consuming a safe nonce so a signed request can't replay. Binding
    ///      chain id + module + safe + resolved TopUp + assets + amount + minimum + deadline means the
    ///      signature cannot be reused for another route or recipient.
    function _verifySignatures(address safe, address topUp, bytes32 requestHash, address[] calldata signers, bytes[] calldata signatures) private {
        bytes32 digest = keccak256(abi.encodePacked(DEPOSIT_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe, topUp, requestHash)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignature();
    }

    /// @inheritdoc ITradingSafeLiquidDepositModule
    function addLiquidAssets(address[] calldata liquidAssets, address[] calldata tellers) external {
        if (!_roleRegistry().hasRole(TRADING_SAFE_LIQUID_DEPOSIT_MODULE_ADMIN, msg.sender)) {
            revert Unauthorized();
        }
        _setLiquidAssets(liquidAssets, tellers);
    }

    /// @inheritdoc ITradingSafeLiquidDepositModule
    function removeLiquidAssets(address[] calldata liquidAssets) external {
        if (!_roleRegistry().hasRole(TRADING_SAFE_LIQUID_DEPOSIT_MODULE_ADMIN, msg.sender)) {
            revert Unauthorized();
        }
        uint256 len = liquidAssets.length;
        if (len == 0) revert EmptyArray();

        for (uint256 i = 0; i < len;) {
            delete liquidAssetToTeller[liquidAssets[i]];
            unchecked {
                ++i;
            }
        }

        emit LiquidAssetsRemoved(liquidAssets);
    }

    function _setLiquidAssets(address[] memory liquidAssets, address[] memory tellers) private {
        uint256 len = liquidAssets.length;
        if (len != tellers.length) revert ConfigArrayLengthMismatch();
        if (len == 0) revert EmptyArray();

        for (uint256 i = 0; i < len;) {
            address liquidAsset = liquidAssets[i];
            address teller = tellers[i];
            if (liquidAsset == address(0) || teller == address(0)) revert InvalidConfiguration();
            if (address(ILayerZeroTeller(teller).vault()) != liquidAsset) {
                revert InvalidConfiguration();
            }
            liquidAssetToTeller[liquidAsset] = ILayerZeroTeller(teller);
            unchecked {
                ++i;
            }
        }

        emit LiquidAssetsAdded(liquidAssets, tellers);
    }

    /// @notice Pause new deposits. PAUSER role only.
    function pause() external {
        _roleRegistry().onlyPauser(msg.sender);
        _pause();
    }

    /// @notice Unpause deposits. UNPAUSER role only.
    function unpause() external {
        _roleRegistry().onlyUnpauser(msg.sender);
        _unpause();
    }

    function _roleRegistry() internal view returns (IRoleRegistry) {
        return IRoleRegistry(etherFiDataProvider.roleRegistry());
    }
}
