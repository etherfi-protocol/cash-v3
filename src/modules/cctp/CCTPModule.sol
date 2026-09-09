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
 * @notice Bridge module that moves a CCTP-enabled token (e.g. USDC) out of an EtherFiSafe to another
 *         chain by burning it through Circle's Cross-Chain Transfer Protocol (CCTP v2).
 * @dev Mirrors the StargateModule shape: `requestBridge` queues a CashModule withdrawal to this module,
 *      and `executeBridge` performs the actual burn once the CashModule withdrawal delay has elapsed.
 *      When the configured delay is zero the burn happens inline inside `requestBridge`.
 *
 *      Fees: CCTP charges no native messaging fee. Two fees are taken in the bridged token itself:
 *        - `providerFee`  — EtherFi's service fee, transferred to `providerFeeRecipient` on the source
 *                           chain before the burn. Deducted from the signed `amount`.
 *        - `maxFee`       — the ceiling Circle may deduct on the destination for relaying/attesting the
 *                           message. Passed to `depositForBurn`; only charged for Fast transfers.
 *      So: burnAmount = amount - providerFee, and the recipient receives burnAmount - (Circle's actual
 *      fee, <= maxFee) on the destination chain.
 *
 *      Trust model: the fee ceilings (`maxFeeBps`, `providerFeeBps`), the fee recipient and the CCTP
 *      TokenMessenger are *admin-configured* — they are NOT supplied by the (signed) request. The signed
 *      request only authorizes {destDomain, asset, amount, destRecipient, finalityThreshold}, which means
 *      an admin config change between signing and `requestBridge` applies to that request. Once the request
 *      is queued, the resolved {tokenMessenger, maxFee, providerFee, providerFeeRecipient} are snapshotted
 *      into the pending withdrawal, so a later admin change cannot alter an already-queued bridge.
 * @custom:security-contact security@etherfi.io
 */
contract CCTPModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient, IBridgeModule {
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    /// @notice Basis-points denominator (100% = 10_000 bps).
    uint256 public constant MAX_BPS = 10_000;

    /**
     * @notice Hard ceiling (5%) on every admin-configured bps value.
     * @dev Defensive: prevents a fat-finger from authorizing a fee that consumes a large fraction of
     *      the transfer. Applied to both `AssetConfig.maxFeeBps` and `AssetConfig.providerFeeBps`.
     */
    uint256 public constant MAX_FEE_BPS = 500;

    /**
     * @notice CCTP "Confirmed" finality threshold — a Fast transfer.
     * @dev Circle attests before source-chain hard finality and charges a relay fee for the risk, so
     *      requests using this threshold burn with a non-zero `maxFee`.
     */
    uint32 public constant FINALITY_CONFIRMED = 1000;

    /**
     * @notice CCTP "Finalized" finality threshold — a Standard transfer.
     * @dev Circle waits for source-chain hard finality; free on TokenMessengerV2, so requests using this
     *      threshold always burn with `maxFee = 0`.
     */
    uint32 public constant FINALITY_FINALIZED = 2000;

    /**
     * @notice Per-asset admin configuration.
     * @param tokenMessenger CCTP TokenMessenger contract for this burn-token on this chain.
     *                       address(0) means the asset is unsupported and bridging it reverts.
     * @param maxFeeBps Ceiling on Circle's relay fee, in bps of the *burn amount*. Only applied when the
     *                  signed request selects Fast (`FINALITY_CONFIRMED`) finality; Standard requests always
     *                  burn with maxFee = 0. Must be <= MAX_FEE_BPS.
     * @param providerFeeBps EtherFi service fee, in bps of the *gross signed amount*, paid on the source
     *                       chain to the module-wide `providerFeeRecipient`. Must be <= MAX_FEE_BPS.
     */
    struct AssetConfig {
        address tokenMessenger;
        uint256 maxFeeBps;
        uint256 providerFeeBps;
    }

    /**
     * @notice A bridge that has been authorized and queued, awaiting `executeBridge`.
     * @dev Everything resolved from admin config at request time is frozen here, so admin changes made
     *      while the withdrawal delay runs cannot alter the terms the signers authorized.
     * @param destDomain CCTP domain id of the destination chain.
     * @param asset Token being bridged (the CCTP burn-token).
     * @param amount Gross amount signed by the safe owners, before any fee is taken.
     * @param destRecipient Recipient on the destination chain, left-padded to bytes32.
     * @param tokenMessenger TokenMessenger snapshotted from `AssetConfig` at request time.
     * @param maxFee Ceiling Circle may deduct on the destination, in burn-token. Zero for Standard transfers.
     * @param minFinalityThreshold Finality threshold passed to `depositForBurn` (CONFIRMED or FINALIZED).
     * @param providerFee Absolute EtherFi service fee in burn-token, computed at request time.
     * @param providerFeeRecipient Recipient of `providerFee`, snapshotted at request time.
     */
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

    /**
     * @notice The user-signed parameters of a bridge request.
     * @dev These are the only bridge terms the safe owners authorize; everything else is admin config.
     * @param destDomain CCTP domain id of the destination chain. Must be allowlisted for `asset`.
     * @param asset Token to bridge. Must have a configured TokenMessenger.
     * @param amount Gross amount to withdraw from the safe, inclusive of the EtherFi service fee.
     * @param destRecipient Recipient on the destination chain as bytes32, for non-EVM support.
     *                      EVM callers pass `bytes32(uint256(uint160(addr)))`. Must be non-zero.
     * @param finalityThreshold Transfer mode — `FINALITY_CONFIRMED` (Fast, pays a relay fee) or
     *                          `FINALITY_FINALIZED` (Standard, free). Any other value reverts.
     */
    struct BridgeParams {
        uint32 destDomain;
        address asset;
        uint256 amount;
        bytes32 destRecipient;
        uint32 finalityThreshold;
    }

    /**
     * @dev Storage structure for CCTPModule using the ERC-7201 namespaced diamond storage pattern.
     * @custom:storage-location erc7201:etherfi.storage.CCTPModule
     */
    struct CCTPModuleStorage {
        /// @notice Admin config per supported burn-token.
        mapping(address token => AssetConfig assetConfig) assetConfig;
        /// @notice Allowlist of (token, destination domain) routes that may be bridged.
        mapping(address token => mapping(uint32 domain => bool)) allowedRoute;
        /// @notice At most one queued bridge per safe, keyed by safe address.
        mapping(address safe => CrossChainWithdrawal withdrawal) withdrawals;
        /// @notice Module-wide recipient of the EtherFi service fee. address(0) disables service fees.
        address providerFeeRecipient;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.CCTPModule")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Storage location for the module's storage.
    bytes32 private constant CCTPModuleStorageLocation = 0x8acda1cfca4f5cfd72da8b3438a383a2a5be2d370022c8dfe2b3e8c2690b2e00;

    /// @notice Role in the RoleRegistry permitted to configure assets, routes and the fee recipient.
    bytes32 public constant CCTP_MODULE_ADMIN_ROLE = keccak256("CCTP_MODULE_ADMIN_ROLE");

    /// @notice Domain separator prefix for the `requestBridge` signature digest.
    bytes32 public constant REQUEST_BRIDGE_SIG = keccak256("cctpRequestBridge");
    /// @notice Domain separator prefix for the `cancelBridge` signature digest.
    bytes32 public constant CANCEL_BRIDGE_SIG = keccak256("cctpCancelBridge");

    /// @notice Thrown when the supplied signers/signatures do not satisfy the safe's threshold.
    error InvalidSignatures();
    /// @notice Thrown when this module holds less of the asset than the bridge needs at burn time.
    error InsufficientAmount();
    /// @notice Thrown when the asset has no configured TokenMessenger.
    error UnsupportedAsset();
    /// @notice Thrown when the (asset, destination domain) pair is not allowlisted.
    error UnsupportedRoute();
    /// @notice Thrown when the caller lacks the required role or is not the expected contract.
    error Unauthorized();
    /// @notice Thrown when no bridge is queued for the safe.
    error NoWithdrawalQueuedForCCTP();
    /// @notice Thrown when the CashModule's pending withdrawal does not match the queued bridge.
    error CannotFindMatchingWithdrawalForSafe();
    /// @notice Thrown when the computed CCTP maxFee would consume the entire burn amount.
    error MaxFeeExceedsAmount();
    /// @notice Thrown when `finalityThreshold` is neither FINALITY_CONFIRMED nor FINALITY_FINALIZED.
    error InvalidFinalityThreshold();
    /// @notice Thrown when an admin sets `maxFeeBps` above MAX_FEE_BPS.
    error MaxFeeBpsTooHigh();
    /// @notice Thrown when an admin sets `providerFeeBps` above MAX_FEE_BPS.
    error providerFeeBpsTooHigh();
    /// @notice Thrown when a service fee is owed but no `providerFeeRecipient` is configured.
    error providerFeeRecipientNotSet();
    /// @notice Thrown when the service fee would consume the entire amount, leaving nothing to burn.
    error BurnAmountZero();
    /// @notice Thrown when a non-zero TokenMessenger address has no deployed code.
    error InvalidTokenMessenger();
    /// @notice Thrown when the burn exceeds Circle's per-message burn limit for the token.
    /// @param burnAmount Amount the module attempted to burn.
    /// @param limit Current per-message limit reported by the CCTP TokenMinter.
    error BurnExceedsCctpLimit(uint256 burnAmount, uint256 limit);

    /**
     * @notice Emitted when per-asset configuration is set, at deploy or by an admin.
     * @param assets Assets configured in this call.
     * @param assetConfigs New configuration for each asset, index-aligned with `assets`.
     */
    event AssetConfigSet(address[] assets, AssetConfig[] assetConfigs);

    /**
     * @notice Emitted when destination-domain allowlist entries are set for an asset.
     * @param asset Asset whose routes changed.
     * @param domains CCTP destination domain ids updated in this call.
     * @param allowed New allow/deny flag for each domain, index-aligned with `domains`.
     */
    event AllowedRoutesSet(address indexed asset, uint32[] domains, bool[] allowed);

    /**
     * @notice Emitted when the module-wide service fee recipient changes.
     * @param recipient New recipient; address(0) disables service fees.
     */
    event providerFeeRecipientSet(address indexed recipient);

    /**
     * @notice Emitted when the EtherFi service fee is transferred on the source chain.
     * @param safe Safe whose bridge paid the fee.
     * @param asset Token the fee was paid in (the burn-token).
     * @param fee Fee amount transferred.
     * @param recipient Address that received the fee.
     */
    event providerFeeCharged(address indexed safe, address indexed asset, uint256 fee, address indexed recipient);

    /**
     * @notice Emitted when a bridge is authorized, whether it is queued or burned in the same tx.
     * @param safe Safe initiating the bridge.
     * @param destDomain CCTP domain id of the destination chain.
     * @param asset Token being bridged.
     * @param amount Gross amount signed by the user (before the service fee).
     * @param destRecipient Destination recipient, left-padded to bytes32.
     * @param maxFee Ceiling Circle may deduct on the destination. Zero for Standard transfers.
     * @param minFinalityThreshold Finality threshold the transfer was authorized with.
     * @param providerFee EtherFi service fee resolved for this request.
     */
    event RequestBridgeWithCCTP(address indexed safe, uint32 indexed destDomain, address indexed asset, uint256 amount, bytes32 destRecipient, uint256 maxFee, uint32 minFinalityThreshold, uint256 providerFee);

    /**
     * @notice Emitted when the CCTP burn actually happens.
     * @param safe Safe whose funds were burned.
     * @param destDomain CCTP domain id of the destination chain.
     * @param asset Token burned.
     * @param amount Gross amount signed by the user (before provider fee).
     * @param burnAmount Amount actually burned via CCTP (amount - providerFee). This is what mints on
     *                   destination minus Circle's `maxFee`. Indexers should use burnAmount for
     *                   delivered-USDC accounting.
     * @param mintRecipient Destination recipient, left-padded to bytes32.
     * @param tokenMessenger TokenMessenger the burn was routed through.
     * @param maxFee Ceiling passed to `depositForBurn`.
     * @param minFinalityThreshold Finality threshold passed to `depositForBurn`.
     * @param providerFee EtherFi service fee taken on the source chain.
     */
    event BridgeWithCCTP(address indexed safe, uint32 indexed destDomain, address indexed asset, uint256 amount, uint256 burnAmount, bytes32 mintRecipient, address tokenMessenger, uint256 maxFee, uint32 minFinalityThreshold, uint256 providerFee);

    /**
     * @notice Emitted when a queued bridge is cancelled, by the safe owners or by the CashModule.
     * @param safe Safe whose bridge was cancelled.
     * @param destDomain CCTP domain id the cancelled bridge targeted.
     * @param asset Token the cancelled bridge would have burned.
     * @param amount Gross amount of the cancelled bridge.
     * @param destRecipient Destination recipient of the cancelled bridge.
     */
    event BridgeCancelled(address indexed safe, uint32 indexed destDomain, address indexed asset, uint256 amount, bytes32 destRecipient);

    /**
     * @notice Deploys the module with an initial set of asset configurations.
     * @dev Routes start empty — `setAllowedRoutes` must be called before any bridge can be requested.
     * @param _assets Assets to configure at deploy time.
     * @param _assetConfigs Configuration for each asset, index-aligned with `_assets`.
     * @param _etherFiDataProvider EtherFiDataProvider used to resolve the RoleRegistry and CashModule.
     */
    constructor(address[] memory _assets, AssetConfig[] memory _assetConfigs, address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        _setAssetConfigs(_assets, _assetConfigs);
    }

    /**
     * @dev Returns the ERC-7201 namespaced storage pointer for this module.
     * @return $ Storage struct at `CCTPModuleStorageLocation`.
     */
    function _getCCTPModuleStorage() internal pure returns (CCTPModuleStorage storage $) {
        assembly { $.slot := CCTPModuleStorageLocation }
    }

    /**
     * @notice Returns the admin configuration for an asset.
     * @param asset Token to look up.
     * @return Configuration for `asset`; a zero `tokenMessenger` means unsupported.
     */
    function getAssetConfig(address asset) external view returns (AssetConfig memory) {
        return _getCCTPModuleStorage().assetConfig[asset];
    }

    /**
     * @notice Returns the bridge currently queued for a safe.
     * @param safe Safe to look up.
     * @return The queued bridge; a zero `destRecipient` means nothing is queued.
     */
    function getPendingBridge(address safe) external view returns (CrossChainWithdrawal memory) {
        return _getCCTPModuleStorage().withdrawals[safe];
    }

    /**
     * @notice Sets the admin configuration for one or more assets.
     * @dev Only callable by CCTP_MODULE_ADMIN_ROLE. Setting `tokenMessenger` to address(0) delists the
     *      asset for new requests; already-queued bridges keep their snapshotted messenger and still execute.
     * @param assets Assets to configure.
     * @param assetConfigs Configuration for each asset, index-aligned with `assets`.
     */
    function setAssetConfig(address[] memory assets, AssetConfig[] memory assetConfigs) external {
        _onlyAdmin();
        _setAssetConfigs(assets, assetConfigs);
    }

    /**
     * @notice Returns whether an asset may be bridged to a given CCTP destination domain.
     * @param asset Token to check.
     * @param domain CCTP destination domain id.
     * @return True if the route is allowlisted.
     */
    function isRouteAllowed(address asset, uint32 domain) external view returns (bool) {
        return _getCCTPModuleStorage().allowedRoute[asset][domain];
    }

    /**
     * @notice Allows or denies destination domains for a given asset.
     * @dev Only callable by CCTP_MODULE_ADMIN_ROLE. The allowlist is checked at request time only —
     *      revoking a route does not block an already-queued bridge from executing.
     * @param asset Token whose routes are being updated.
     * @param domains CCTP destination domain ids to update.
     * @param allowed Allow/deny flag for each domain, index-aligned with `domains`.
     */
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

    /// @dev Reverts unless `msg.sender` holds CCTP_MODULE_ADMIN_ROLE in the RoleRegistry.
    function _onlyAdmin() internal view {
        if (!IRoleRegistry(etherFiDataProvider.roleRegistry()).hasRole(CCTP_MODULE_ADMIN_ROLE, msg.sender)) revert Unauthorized();
    }

    /**
     * @notice Returns the module-wide recipient of the EtherFi service fee.
     * @return Current recipient; address(0) means service fees are disabled.
     */
    function getproviderFeeRecipient() external view returns (address) {
        return _getCCTPModuleStorage().providerFeeRecipient;
    }

    /**
     * @notice Sets the module-wide recipient of the EtherFi service fee.
     * @dev Only callable by CCTP_MODULE_ADMIN_ROLE. Recipient can be address(0) to disable service fees
     *      (any asset with providerFeeBps > 0 will then revert on request).
     * @param recipient New fee recipient.
     */
    function setproviderFeeRecipient(address recipient) external {
        _onlyAdmin();
        _getCCTPModuleStorage().providerFeeRecipient = recipient;
        emit providerFeeRecipientSet(recipient);
    }

    /**
     * @notice Quotes the EtherFi service fee for a gross bridge amount.
     * @param asset Token to be bridged.
     * @param amount Gross amount, as it would be signed in `BridgeParams.amount`.
     * @return Service fee in `asset`, deducted before the CCTP burn.
     */
    function getproviderFee(address asset, uint256 amount) external view returns (uint256) {
        AssetConfig memory cfg = _getCCTPModuleStorage().assetConfig[asset];
        if (cfg.tokenMessenger == address(0)) revert UnsupportedAsset();
        return _computeMaxFee(amount, cfg.providerFeeBps);
    }

    /**
     * @notice Quotes both fees for a bridge, so a caller can show the user what will be delivered.
     * @dev The destination recipient receives at least `amount - providerFee - cctpMaxFee`; Circle may
     *      charge less than `cctpMaxFee`. Reverts if the asset is unsupported.
     * @param asset Token to be bridged.
     * @param amount Gross amount, as it would be signed in `BridgeParams.amount`.
     * @param finalityThreshold Transfer mode to quote for (FINALITY_CONFIRMED or FINALITY_FINALIZED).
     * @return feeToken Token both fees are denominated in — always `asset`.
     * @return providerFee EtherFi service fee taken on the source chain.
     * @return cctpMaxFee Ceiling Circle may deduct on the destination; zero for Standard transfers.
     */
    function getBridgeFee(address asset, uint256 amount, uint32 finalityThreshold) external view returns (address feeToken, uint256 providerFee, uint256 cctpMaxFee) {
        AssetConfig memory cfg = _getCCTPModuleStorage().assetConfig[asset];
        if (cfg.tokenMessenger == address(0)) revert UnsupportedAsset();
        providerFee = _computeMaxFee(amount, cfg.providerFeeBps);
        cctpMaxFee = finalityThreshold == FINALITY_CONFIRMED ? _computeMaxFee(amount - providerFee, cfg.maxFeeBps) : 0;
        feeToken = asset;
    }

    /**
     * @notice Authorizes a CCTP bridge for a safe and queues the corresponding CashModule withdrawal.
     * @dev Fees, TokenMessenger and the fee recipient are resolved from admin config here, not from `p`,
     *      and are then frozen into the queued record. If the CashModule withdrawal delay is zero the burn
     *      is performed in this same transaction; otherwise it awaits `executeBridge`.
     *
     *      Any bridge already queued for `safe` is discarded — the CashModule allows only one pending
     *      withdrawal per safe, so a leftover record could only be an orphan.
     * @param safe EtherFiSafe initiating the bridge.
     * @param p Signed bridge params — destination domain, asset, gross amount, recipient, transfer mode.
     * @param signers Threshold signers over the request digest.
     * @param signatures Signatures matching `signers`.
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

    /**
     * @dev Validates the transfer mode and resolves the request into a fully-priced withdrawal record.
     *      Fee arithmetic: providerFee is bps of the gross amount, CCTP's maxFee is bps of what remains.
     * @param p Signed bridge params.
     * @param cfg Admin configuration for `p.asset`, read by the caller.
     * @return w Withdrawal record with fees and the TokenMessenger snapshotted.
     */
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

    /**
     * @notice Executes a previously queued bridge once the CashModule withdrawal delay has elapsed.
     * @dev Permissionless — the terms were already authorized at request time, so anyone may finalize.
     *      Pulls the funds out of the safe via `processWithdrawal`, then burns on the snapshotted terms.
     *      Reverts if the CashModule's pending withdrawal no longer matches the queued bridge, or if the
     *      delay has not yet elapsed (enforced by the CashModule).
     * @param safe Safe whose queued bridge should be executed.
     */
    function executeBridge(address safe) external nonReentrant onlyEtherFiSafe(safe) {
        CrossChainWithdrawal memory w = _getCCTPModuleStorage().withdrawals[safe];
        if (w.destRecipient == bytes32(0)) revert NoWithdrawalQueuedForCCTP();

        WithdrawalRequest memory wr = cashModule.getData(safe).pendingWithdrawalRequest;
        if (wr.recipient != address(this) || wr.tokens.length != 1 || wr.tokens[0] != w.asset || wr.amounts[0] != w.amount) revert CannotFindMatchingWithdrawalForSafe();

        delete _getCCTPModuleStorage().withdrawals[safe];

        cashModule.processWithdrawal(safe);

        // Snapshot captured at request time; route allowlist deliberately NOT re-checked.
        _bridge(safe, w);
    }

    /**
     * @notice Cancels a queued bridge and the underlying CashModule withdrawal.
     * @dev Requires threshold signatures over the cancel digest, which consumes a safe nonce and so
     *      invalidates any other request signed against that nonce.
     * @param safe Safe whose queued bridge should be cancelled.
     * @param signers Threshold signers over the cancel digest.
     * @param signatures Signatures matching `signers`.
     */
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

    /**
     * @inheritdoc IBridgeModule
     * @dev Callback for when the CashModule cancels the withdrawal from its own side (e.g. the safe's
     *      collateral is needed to service spending). Returns silently when nothing is queued, so it is
     *      safe to call after `cancelBridge` has already cleared the record.
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != etherFiDataProvider.getCashModule()) revert Unauthorized();

        CrossChainWithdrawal storage w = _getCCTPModuleStorage().withdrawals[safe];
        if (w.destRecipient == bytes32(0)) return;

        emit BridgeCancelled(safe, w.destDomain, w.asset, w.amount, w.destRecipient);
        delete _getCCTPModuleStorage().withdrawals[safe];
    }

    /**
     * @dev Pays the service fee and burns the remainder through CCTP. Assumes the module already holds
     *      `w.amount` of `w.asset`. The per-message burn limit is re-checked here because Circle can
     *      tighten it between request and execution.
     * @param safe Safe the bridge belongs to; used only for event attribution.
     * @param w Fully-resolved withdrawal record, snapshotted at request time.
     */
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

    /**
     * @dev Applies a bps rate to an amount, rounding down.
     * @param amount Base the rate applies to.
     * @param maxFeeBps Rate in basis points.
     * @return Resulting fee; zero when the rate is zero.
     */
    function _computeMaxFee(uint256 amount, uint256 maxFeeBps) internal pure returns (uint256) {
        if (maxFeeBps == 0) return 0;
        return (amount * maxFeeBps) / MAX_BPS;
    }

    /**
     * @dev Validates and writes per-asset configuration. Shared by the constructor and `setAssetConfig`.
     *      Both bps values are capped at MAX_FEE_BPS, and a non-zero TokenMessenger must have code.
     * @param assets Assets to configure.
     * @param assetConfigs Configuration for each asset, index-aligned with `assets`.
     */
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

    /**
     * @dev Reverts unless this module holds at least `amount` of `asset`.
     * @param asset Token to check.
     * @param amount Required balance.
     */
    function _checkBalance(address asset, uint256 amount) internal view {
        if (IERC20(asset).balanceOf(address(this)) < amount) revert InsufficientAmount();
    }
}
