// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../../interfaces/IRoleRegistry.sol";
import { ICCTPTokenMessenger } from "../../interfaces/ICCTPTokenMessenger.sol";
import { ICCTPTokenMinter } from "../../interfaces/ICCTPTokenMinter.sol";
import { WithdrawalRequest, SafeData } from "../../interfaces/ICashModule.sol";
import { IBridgeModule } from "../../interfaces/IBridgeModule.sol";

/**
 * @title CCTPModule
 * @author EtherFi
 * @notice Delayed bridge module that burns USDC via Circle CCTP for cross-chain transfer.
 * @dev Mirrors StargateModule shape; CCTP has no native messaging fee — the destination relay/attestation
 *      fee is paid in burn-token via `maxFee` on `depositForBurn`.
 *
 *      Trust model: transfer mode (finality threshold), fee ceiling (maxFeeBps), and the CCTP
 *      TokenMessenger are *admin-configured per asset* — they are NOT supplied by the (signed) request.
 *      The signed request only authorizes {destDomain, asset, amount, destRecipient}. At request time the
 *      resolved {tokenMessenger, maxFee, minFinalityThreshold} are snapshotted into the queued withdrawal
 *      so a later admin config change cannot alter an already-authorized bridge before `executeBridge`.
 * @custom:security-contact security@etherfi.io
 */
contract CCTPModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient, IBridgeModule {
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    /// @dev Basis-points denominator.
    uint256 public constant MAX_BPS = 10_000;
    /// @dev Defensive ceiling on the admin-configured fee, to prevent a fat-finger from
    ///      authorizing a fee that consumes a large fraction of the transfer (5%).
    uint256 public constant MAX_FEE_BPS = 500;
    /// @dev CCTP "Confirmed" finality (Fast transfer).
    uint32 public constant FINALITY_CONFIRMED = 1000;
    /// @dev CCTP "Finalized" finality (Standard transfer).
    uint32 public constant FINALITY_FINALIZED = 2000;

    /**
     * @notice Per-asset admin configuration.
     * @param tokenMessenger CCTP TokenMessenger contract for the burn-token on this chain.
     *                       address(0) = unsupported asset.
     * @param maxFeeBps Admin ceiling on the CCTP relay-fee in bps of the *burn amount*, applied only
     *                  when the signed request selects Fast (CONFIRMED) finality. Standard requests
     *                  always burn with maxFee=0. Must be <= MAX_FEE_BPS.
     * @param providerFeeBps Provider service fee (paid to feeRecipient on source in burn-token).
     */
    struct AssetConfig {
        address tokenMessenger;
        uint256 maxFeeBps;
        uint256 providerFeeBps;
    }

    struct CrossChainWithdrawal {
        uint32 destDomain;
        address asset;
        uint256 amount;
        bytes32 destRecipient;
        address tokenMessenger;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        uint256 providerFee;
        address providerFeeRecipient;
    }

    /// @dev destRecipient is bytes32 for non-EVM support; EVM callers pass bytes32(uint256(uint160(addr))).
    ///      tokenMessenger/maxFeeBps/providerFeeBps commit the signer to the AssetConfig snapshot they quoted against.
    struct BridgeParams {
        uint32 destDomain;
        address asset;
        uint256 amount;
        bytes32 destRecipient;
        uint32 finalityThreshold;
        address tokenMessenger;
        uint256 maxFeeBps;
        uint256 providerFeeBps;
        address providerFeeRecipient;
    }

    /// @custom:storage-location erc7201:etherfi.storage.CCTPModule
    struct CCTPModuleStorage {
        mapping(address token => AssetConfig assetConfig) assetConfig;
        mapping(address token => mapping(uint32 domain => bool)) allowedRoute;
        mapping(address safe => CrossChainWithdrawal withdrawal) withdrawals;
        address providerFeeRecipient;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.CCTPModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CCTPModuleStorageLocation = 0x8acda1cfca4f5cfd72da8b3438a383a2a5be2d370022c8dfe2b3e8c2690b2e00;

    bytes32 public constant CCTP_MODULE_ADMIN_ROLE = keccak256("CCTP_MODULE_ADMIN_ROLE");

    bytes32 public constant REQUEST_BRIDGE_SIG = keccak256("cctpRequestBridge");
    bytes32 public constant CANCEL_BRIDGE_SIG = keccak256("cctpCancelBridge");

    error InvalidSignatures();
    error InsufficientAmount();
    error UnsupportedAsset();
    error UnsupportedRoute();
    error Unauthorized();
    error NoWithdrawalQueuedForCCTP();
    error CannotFindMatchingWithdrawalForSafe();
    error MaxFeeExceedsAmount();
    error InvalidFinalityThreshold();
    error MaxFeeBpsTooHigh();
    error providerFeeBpsTooHigh();
    error providerFeeRecipientNotSet();
    error BurnAmountZero();
    error InvalidTokenMessenger();
    error BurnExceedsCctpLimit(uint256 burnAmount, uint256 limit);
    error ConfigChangedSinceSigning();

    event AssetConfigSet(address[] assets, AssetConfig[] assetConfigs);
    event AllowedRoutesSet(address indexed asset, uint32[] domains, bool[] allowed);
    event providerFeeRecipientSet(address indexed recipient);
    event providerFeeCharged(address indexed safe, address indexed asset, uint256 fee, address indexed recipient);
    event RequestBridgeWithCCTP(address indexed safe, uint32 indexed destDomain, address indexed asset, uint256 amount, bytes32 destRecipient, uint256 maxFee, uint32 minFinalityThreshold, uint256 providerFee);
    /// @param amount Gross amount signed by the user (before provider fee).
    /// @param burnAmount Amount actually burned via CCTP (amount - providerFee). This is what mints on destination
    ///                    minus Circle's `maxFee`. Indexers should use burnAmount for delivered-USDC accounting.
    event BridgeWithCCTP(address indexed safe, uint32 indexed destDomain, address indexed asset, uint256 amount, uint256 burnAmount, bytes32 mintRecipient, address tokenMessenger, uint256 maxFee, uint32 minFinalityThreshold, uint256 providerFee);
    event BridgeCancelled(address indexed safe, uint32 indexed destDomain, address indexed asset, uint256 amount, bytes32 destRecipient);

    constructor(address[] memory _assets, AssetConfig[] memory _assetConfigs, address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        _setAssetConfigs(_assets, _assetConfigs);
    }

    function _getCCTPModuleStorage() internal pure returns (CCTPModuleStorage storage $) {
        assembly { $.slot := CCTPModuleStorageLocation }
    }

    function getAssetConfig(address asset) external view returns (AssetConfig memory) {
        return _getCCTPModuleStorage().assetConfig[asset];
    }

    function getPendingBridge(address safe) external view returns (CrossChainWithdrawal memory) {
        return _getCCTPModuleStorage().withdrawals[safe];
    }

    function setAssetConfig(address[] memory assets, AssetConfig[] memory assetConfigs) external {
        _onlyAdmin();
        _setAssetConfigs(assets, assetConfigs);
    }

    function isRouteAllowed(address asset, uint32 domain) external view returns (bool) {
        return _getCCTPModuleStorage().allowedRoute[asset][domain];
    }

    function setAllowedRoutes(address asset, uint32[] calldata domains, bool[] calldata allowed) external {
        _onlyAdmin();
        if (asset == address(0)) revert InvalidInput();
        if (domains.length != allowed.length) revert ArrayLengthMismatch();
        CCTPModuleStorage storage $ = _getCCTPModuleStorage();
        for (uint256 i = 0; i < domains.length; ) {
            $.allowedRoute[asset][domains[i]] = allowed[i];
            unchecked { ++i; }
        }
        emit AllowedRoutesSet(asset, domains, allowed);
    }

    function _onlyAdmin() internal view {
        if (!IRoleRegistry(etherFiDataProvider.roleRegistry()).hasRole(CCTP_MODULE_ADMIN_ROLE, msg.sender)) revert Unauthorized();
    }

    function getproviderFeeRecipient() external view returns (address) {
        return _getCCTPModuleStorage().providerFeeRecipient;
    }

    /// @notice Recipient can be address(0) to disable service fees (any asset with providerFeeBps>0 will then revert).
    function setproviderFeeRecipient(address recipient) external {
        _onlyAdmin();
        _getCCTPModuleStorage().providerFeeRecipient = recipient;
        emit providerFeeRecipientSet(recipient);
    }

    function getproviderFee(address asset, uint256 amount) external view returns (uint256) {
        AssetConfig memory cfg = _getCCTPModuleStorage().assetConfig[asset];
        if (cfg.tokenMessenger == address(0)) revert UnsupportedAsset();
        return _computeMaxFee(amount, cfg.providerFeeBps);
    }

    function getBridgeFee(address asset, uint256 amount, uint32 finalityThreshold) external view returns (address feeToken, uint256 providerFee, uint256 cctpMaxFee) {
        AssetConfig memory cfg = _getCCTPModuleStorage().assetConfig[asset];
        if (cfg.tokenMessenger == address(0)) revert UnsupportedAsset();
        providerFee = _computeMaxFee(amount, cfg.providerFeeBps);
        cctpMaxFee = finalityThreshold == FINALITY_CONFIRMED ? _computeMaxFee(amount - providerFee, cfg.maxFeeBps) : 0;
        feeToken = asset;
    }

    /**
     * @notice Requests a CCTP bridge for the safe. Queues a CashModule withdrawal; if delay is zero,
     *         executes the burn in the same tx. Transfer mode and fee are taken from admin config.
     * @param safe EtherFiSafe initiating the bridge.
     * @param p Signed bridge params (domain, asset, amount, recipient).
     * @param signers Threshold signers over the request digest.
     * @param signatures Matching signatures.
     */
    function requestBridge(
        address safe,
        BridgeParams calldata p,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external nonReentrant onlyEtherFiSafe(safe) {
        if (p.destRecipient == bytes32(0) || p.asset == address(0) || p.amount == 0) revert InvalidInput();

        CCTPModuleStorage storage $ = _getCCTPModuleStorage();
        AssetConfig memory cfg = $.assetConfig[p.asset];
        if (cfg.tokenMessenger == address(0)) revert UnsupportedAsset();
        if (!$.allowedRoute[p.asset][p.destDomain]) revert UnsupportedRoute();
        if (cfg.tokenMessenger != p.tokenMessenger || cfg.maxFeeBps != p.maxFeeBps || cfg.providerFeeBps != p.providerFeeBps || $.providerFeeRecipient != p.providerFeeRecipient) revert ConfigChangedSinceSigning();

        bytes32 digestHash = keccak256(abi.encodePacked(
            REQUEST_BRIDGE_SIG,
            block.chainid,
            address(this),
            IEtherFiSafe(safe).useNonce(),
            safe,
            abi.encode(p)
        )).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();

        CrossChainWithdrawal memory w = _buildWithdrawal(p, cfg);

        // Scoped so locals release before the CashModule call (stack depth).
        {
            uint256 limit = ICCTPTokenMinter(ICCTPTokenMessenger(cfg.tokenMessenger).localMinter()).burnLimitsPerMessage(p.asset);
            uint256 burnAmt = p.amount - w.providerFee;
            if (burnAmt > limit) revert BurnExceedsCctpLimit(burnAmt, limit);
        }

        cashModule.requestWithdrawalByModule(safe, p.asset, p.amount);

        emit RequestBridgeWithCCTP(safe, w.destDomain, w.asset, w.amount, w.destRecipient, w.maxFee, w.minFinalityThreshold, w.providerFee);

        (uint64 withdrawalDelay, , ) = cashModule.getDelays();
        // Clear any residual record; a stale entry would either be overwritten (delayed) or
        // survive as an orphan pointing at a burn we just processed (zero-delay).
        delete $.withdrawals[safe];
        if (withdrawalDelay == 0) _bridge(safe, w);
        else $.withdrawals[safe] = w;
    }

    function _buildWithdrawal(BridgeParams calldata p, AssetConfig memory cfg) internal view returns (CrossChainWithdrawal memory w) {
        if (p.finalityThreshold != FINALITY_CONFIRMED && p.finalityThreshold != FINALITY_FINALIZED) revert InvalidFinalityThreshold();

        uint256 providerFee = _computeMaxFee(p.amount, cfg.providerFeeBps);
        address feeRecipient = _getCCTPModuleStorage().providerFeeRecipient;
        if (providerFee > 0 && feeRecipient == address(0)) revert providerFeeRecipientNotSet();

        // CCTP maxFee is applied on the burn amount (amount minus our service fee), not the gross amount.
        uint256 burnAmount = p.amount - providerFee;
        // Unreachable while MAX_FEE_BPS < 10_000 (service fee capped at 5%); kept as defense-in-depth
        // if the cap is ever raised.
        if (burnAmount == 0) revert BurnAmountZero();
        // Standard/FINALIZED transfers are free on OP's TokenMessengerV2 → force maxFee=0. Fast/CONFIRMED
        // requests pay up to the admin ceiling in bps of burnAmount.
        uint256 maxFee = p.finalityThreshold == FINALITY_CONFIRMED ? _computeMaxFee(burnAmount, cfg.maxFeeBps) : 0;
        // Defensive: fee must never consume the whole burn. Guaranteed by MAX_FEE_BPS, re-checked for tiny amounts.
        if (maxFee >= burnAmount) revert MaxFeeExceedsAmount();

        w = CrossChainWithdrawal({
            destDomain: p.destDomain,
            asset: p.asset,
            amount: p.amount,
            destRecipient: p.destRecipient,
            tokenMessenger: cfg.tokenMessenger,
            maxFee: maxFee,
            minFinalityThreshold: p.finalityThreshold,
            providerFee: providerFee,
            providerFeeRecipient: feeRecipient
        });
    }

    function executeBridge(address safe) external nonReentrant onlyEtherFiSafe(safe) {
        CrossChainWithdrawal memory w = _getCCTPModuleStorage().withdrawals[safe];
        if (w.destRecipient == bytes32(0)) revert NoWithdrawalQueuedForCCTP();

        WithdrawalRequest memory wr = cashModule.getData(safe).pendingWithdrawalRequest;
        if (wr.recipient != address(this) || wr.tokens.length != 1 || wr.tokens[0] != w.asset || wr.amounts[0] != w.amount) revert CannotFindMatchingWithdrawalForSafe();

        cashModule.processWithdrawal(safe);

        // Snapshot captured at request time; route allowlist deliberately NOT re-checked.
        _bridge(safe, w);

        delete _getCCTPModuleStorage().withdrawals[safe];
    }

    function cancelBridge(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        bytes32 digestHash = keccak256(abi.encodePacked(CANCEL_BRIDGE_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();

        CrossChainWithdrawal memory w = _getCCTPModuleStorage().withdrawals[safe];
        if (w.destRecipient == bytes32(0)) revert NoWithdrawalQueuedForCCTP();

        // CEI: clear + emit before the external CashModule call. The callback (cancelBridgeByCashModule)
        // then finds nothing and returns silently, so we don't double-emit with a zeroed storage ref.
        delete _getCCTPModuleStorage().withdrawals[safe];
        emit BridgeCancelled(safe, w.destDomain, w.asset, w.amount, w.destRecipient);

        SafeData memory data = cashModule.getData(safe);
        if (data.pendingWithdrawalRequest.recipient == address(this)) cashModule.cancelWithdrawalByModule(safe);
    }

    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != etherFiDataProvider.getCashModule()) revert Unauthorized();

        CrossChainWithdrawal storage w = _getCCTPModuleStorage().withdrawals[safe];
        if (w.destRecipient == bytes32(0)) return;

        emit BridgeCancelled(safe, w.destDomain, w.asset, w.amount, w.destRecipient);
        delete _getCCTPModuleStorage().withdrawals[safe];
    }

    function _bridge(address safe, CrossChainWithdrawal memory w) internal {
        _checkBalance(w.asset, w.amount);
        if (w.tokenMessenger == address(0)) revert UnsupportedAsset();

        if (w.providerFee > 0) {
            if (w.providerFeeRecipient == address(0)) revert providerFeeRecipientNotSet();
            IERC20(w.asset).safeTransfer(w.providerFeeRecipient, w.providerFee);
            emit providerFeeCharged(safe, w.asset, w.providerFee, w.providerFeeRecipient);
        }

        uint256 burnAmount = w.amount - w.providerFee;

        uint256 limit = ICCTPTokenMinter(ICCTPTokenMessenger(w.tokenMessenger).localMinter()).burnLimitsPerMessage(w.asset);
        if (burnAmount > limit) revert BurnExceedsCctpLimit(burnAmount, limit);

        IERC20(w.asset).forceApprove(w.tokenMessenger, burnAmount);
        ICCTPTokenMessenger(w.tokenMessenger).depositForBurn(
            burnAmount,
            w.destDomain,
            w.destRecipient,
            w.asset,
            bytes32(0),
            w.maxFee,
            w.minFinalityThreshold
        );

        emit BridgeWithCCTP(safe, w.destDomain, w.asset, w.amount, burnAmount, w.destRecipient, w.tokenMessenger, w.maxFee, w.minFinalityThreshold, w.providerFee);
    }

    function _computeMaxFee(uint256 amount, uint256 maxFeeBps) internal pure returns (uint256) {
        if (maxFeeBps == 0) return 0;
        return (amount * maxFeeBps) / MAX_BPS;
    }

    function _setAssetConfigs(address[] memory assets, AssetConfig[] memory assetConfigs) internal {
        uint256 len = assets.length;
        if (len != assetConfigs.length) revert ArrayLengthMismatch();

        CCTPModuleStorage storage $ = _getCCTPModuleStorage();
        for (uint256 i = 0; i < len; ) {
            if (assets[i] == address(0)) revert InvalidInput();
            AssetConfig memory cfg = assetConfigs[i];
            if (cfg.maxFeeBps > MAX_FEE_BPS) revert MaxFeeBpsTooHigh();
            if (cfg.providerFeeBps > MAX_FEE_BPS) revert providerFeeBpsTooHigh();
            if (cfg.tokenMessenger != address(0) && cfg.tokenMessenger.code.length == 0) revert InvalidTokenMessenger();
            $.assetConfig[assets[i]] = cfg;
            unchecked { ++i; }
        }
        emit AssetConfigSet(assets, assetConfigs);
    }

    function _checkBalance(address asset, uint256 amount) internal view {
        if (IERC20(asset).balanceOf(address(this)) < amount) revert InsufficientAmount();
    }
}
