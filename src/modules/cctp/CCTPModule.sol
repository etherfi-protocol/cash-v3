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
     * @param finalityThreshold CCTP finality: 2000 (Standard/free) or 1000 (Fast/fee).
     * @param maxFeeBps CCTP relay-fee ceiling in bps of the *burn amount* (amount - etherFiFee),
     *                  paid to Circle on the destination in burn-token. 0 for Standard transfers.
     *                  Must be <= MAX_FEE_BPS.
     */
    struct AssetConfig {
        address tokenMessenger;
        uint32 finalityThreshold;
        uint256 maxFeeBps;      // CCTP relay-fee ceiling (paid to Circle on destination in burn-token)
        uint256 etherFiFeeBps;  // ether.fi service fee (paid to feeRecipient on source in burn-token)
    }

    /// @dev Queued bridge; snapshots the resolved config so execution cannot drift from what was signed.
    struct CrossChainWithdrawal {
        uint32 destDomain;
        address asset;
        uint256 amount;
        address destRecipient;
        address tokenMessenger;      // snapshot of assetConfig at request time
        uint256 maxFee;              // snapshot: CCTP maxFee computed on burnAmount at request time
        uint32 minFinalityThreshold; // snapshot of assetConfig.finalityThreshold
        uint256 etherFiFee;          // snapshot: etherFiFeeBps * amount at request time
        address etherFiFeeRecipient; // snapshot of module feeRecipient at request time
    }

    /// @dev Signed request params. Fee/finality/messenger are admin-config, NOT included here.
    struct BridgeParams {
        uint32 destDomain;
        address asset;
        uint256 amount;
        address destRecipient;
    }

    /// @custom:storage-location erc7201:etherfi.storage.CCTPModule
    struct CCTPModuleStorage {
        mapping(address token => AssetConfig assetConfig) assetConfig;
        mapping(uint32 domain => bool) allowedDomain;
        mapping(address safe => CrossChainWithdrawal withdrawal) withdrawals;
        address etherFiFeeRecipient;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.CCTPModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CCTPModuleStorageLocation = 0x8acda1cfca4f5cfd72da8b3438a383a2a5be2d370022c8dfe2b3e8c2690b2e00;

    bytes32 public constant CCTP_MODULE_ADMIN_ROLE = keccak256("CCTP_MODULE_ADMIN_ROLE");

    bytes32 public constant REQUEST_BRIDGE_SIG = keccak256("cctpRequestBridge");
    bytes32 public constant CANCEL_BRIDGE_SIG = keccak256("cctpCancelBridge");

    error InvalidSignatures();
    error InsufficientAmount();
    error UnsupportedAsset();
    error UnsupportedDomain();
    error Unauthorized();
    error NoWithdrawalQueuedForCCTP();
    error CannotFindMatchingWithdrawalForSafe();
    error MaxFeeExceedsAmount();
    error InvalidFinalityThreshold();
    error MaxFeeBpsTooHigh();
    error EtherFiFeeBpsTooHigh();
    error StandardModeFeeNotAllowed();
    error EtherFiFeeRecipientNotSet();
    error BurnAmountZero();

    event AssetConfigSet(address[] assets, AssetConfig[] assetConfigs);
    event AllowedDomainsSet(uint32[] domains, bool[] allowed);
    event EtherFiFeeRecipientSet(address indexed recipient);
    event EtherFiFeeCharged(address indexed safe, address indexed asset, uint256 fee, address indexed recipient);
    event RequestBridgeWithCCTP(address indexed safe, uint32 indexed destDomain, address indexed asset, uint256 amount, address destRecipient, uint256 maxFee, uint32 minFinalityThreshold, uint256 etherFiFee);
    /// @param amount Gross amount signed by the user (before ether.fi fee).
    /// @param burnAmount Amount actually burned via CCTP (amount - etherFiFee). This is what mints on destination
    ///                    minus Circle's `maxFee`. Indexers should use burnAmount for delivered-USDC accounting.
    event BridgeWithCCTP(address indexed safe, uint32 indexed destDomain, address indexed asset, uint256 amount, uint256 burnAmount, bytes32 mintRecipient, address tokenMessenger, uint256 maxFee, uint32 minFinalityThreshold, uint256 etherFiFee);
    event BridgeCancelled(address indexed safe, uint32 indexed destDomain, address indexed asset, uint256 amount, address destRecipient);

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

    function isDomainAllowed(uint32 domain) external view returns (bool) {
        return _getCCTPModuleStorage().allowedDomain[domain];
    }

    function setAllowedDomains(uint32[] calldata domains, bool[] calldata allowed) external {
        _onlyAdmin();
        if (domains.length != allowed.length) revert ArrayLengthMismatch();
        CCTPModuleStorage storage $ = _getCCTPModuleStorage();
        for (uint256 i = 0; i < domains.length; ) {
            $.allowedDomain[domains[i]] = allowed[i];
            unchecked { ++i; }
        }
        emit AllowedDomainsSet(domains, allowed);
    }

    function _onlyAdmin() internal view {
        if (!IRoleRegistry(etherFiDataProvider.roleRegistry()).hasRole(CCTP_MODULE_ADMIN_ROLE, msg.sender)) revert Unauthorized();
    }

    function getEtherFiFeeRecipient() external view returns (address) {
        return _getCCTPModuleStorage().etherFiFeeRecipient;
    }

    /// @notice Recipient can be address(0) to disable service fees (any asset with etherFiFeeBps>0 will then revert).
    function setEtherFiFeeRecipient(address recipient) external {
        _onlyAdmin();
        _getCCTPModuleStorage().etherFiFeeRecipient = recipient;
        emit EtherFiFeeRecipientSet(recipient);
    }

    function getEtherFiFee(address asset, uint256 amount) external view returns (uint256) {
        return _computeMaxFee(amount, _getCCTPModuleStorage().assetConfig[asset].etherFiFeeBps);
    }

    /// @notice Total fees deducted from `amount`: ether.fi service fee + CCTP relay fee (both in burn-token).
    /// @dev CCTP maxFee is computed on the burn amount (gross minus ether.fi fee), matching `_buildWithdrawal`.
    /// @return feeToken The burn asset, or ETH sentinel for an unsupported asset.
    /// @return etherFiFee ether.fi service fee (goes to feeRecipient on source).
    /// @return cctpMaxFee CCTP relay-fee ceiling (paid to Circle on destination).
    function getBridgeFee(address asset, uint256 amount) external view returns (address feeToken, uint256 etherFiFee, uint256 cctpMaxFee) {
        AssetConfig memory cfg = _getCCTPModuleStorage().assetConfig[asset];
        if (cfg.tokenMessenger == address(0)) return (ETH, 0, 0);
        etherFiFee = _computeMaxFee(amount, cfg.etherFiFeeBps);
        cctpMaxFee = _computeMaxFee(amount - etherFiFee, cfg.maxFeeBps);
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
        if (p.destRecipient == address(0) || p.asset == address(0) || p.amount == 0) revert InvalidInput();

        AssetConfig memory cfg = _getCCTPModuleStorage().assetConfig[p.asset];
        if (cfg.tokenMessenger == address(0)) revert UnsupportedAsset();
        if (!_getCCTPModuleStorage().allowedDomain[p.destDomain]) revert UnsupportedDomain();

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

        cashModule.requestWithdrawalByModule(safe, p.asset, p.amount);

        emit RequestBridgeWithCCTP(safe, w.destDomain, w.asset, w.amount, w.destRecipient, w.maxFee, w.minFinalityThreshold, w.etherFiFee);

        (uint64 withdrawalDelay, , ) = cashModule.getDelays();
        if (withdrawalDelay == 0) _bridge(safe, w);
        else _getCCTPModuleStorage().withdrawals[safe] = w;
    }

    function _buildWithdrawal(BridgeParams calldata p, AssetConfig memory cfg) internal view returns (CrossChainWithdrawal memory w) {
        uint256 etherFiFee = _computeMaxFee(p.amount, cfg.etherFiFeeBps);
        address feeRecipient = _getCCTPModuleStorage().etherFiFeeRecipient;
        if (etherFiFee > 0 && feeRecipient == address(0)) revert EtherFiFeeRecipientNotSet();

        // CCTP maxFee is applied on the burn amount (amount minus our service fee), not the gross amount.
        uint256 burnAmount = p.amount - etherFiFee;
        // Unreachable while MAX_FEE_BPS < 10_000 (service fee capped at 5%); kept as defense-in-depth
        // if the cap is ever raised.
        if (burnAmount == 0) revert BurnAmountZero();
        uint256 maxFee = _computeMaxFee(burnAmount, cfg.maxFeeBps);
        // Defensive: fee must never consume the whole burn. Guaranteed by MAX_FEE_BPS, re-checked for tiny amounts.
        if (maxFee >= burnAmount) revert MaxFeeExceedsAmount();

        w = CrossChainWithdrawal({
            destDomain: p.destDomain,
            asset: p.asset,
            amount: p.amount,
            destRecipient: p.destRecipient,
            tokenMessenger: cfg.tokenMessenger,
            maxFee: maxFee,
            minFinalityThreshold: cfg.finalityThreshold,
            etherFiFee: etherFiFee,
            etherFiFeeRecipient: feeRecipient
        });
    }

    function executeBridge(address safe) external nonReentrant onlyEtherFiSafe(safe) {
        CrossChainWithdrawal memory w = _getCCTPModuleStorage().withdrawals[safe];
        if (w.destRecipient == address(0)) revert NoWithdrawalQueuedForCCTP();

        WithdrawalRequest memory wr = cashModule.getData(safe).pendingWithdrawalRequest;
        if (wr.recipient != address(this) || wr.tokens.length != 1 || wr.tokens[0] != w.asset || wr.amounts[0] != w.amount) revert CannotFindMatchingWithdrawalForSafe();

        cashModule.processWithdrawal(safe);

        // Use the snapshot captured at request time, NOT a fresh config read — protects against config drift.
        // Note (policy): the destination-domain allowlist is intentionally NOT re-checked here. A bridge that
        // was authorized against an allowed domain stays executable even if the domain is later disabled, so an
        // admin config change cannot strand a queued, already-signed withdrawal. (cancelBridge / CashModule
        // override remain available to unwind it.)
        _bridge(safe, w);

        delete _getCCTPModuleStorage().withdrawals[safe];
    }

    function cancelBridge(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        bytes32 digestHash = keccak256(abi.encodePacked(CANCEL_BRIDGE_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();

        CrossChainWithdrawal storage w = _getCCTPModuleStorage().withdrawals[safe];
        if (w.destRecipient == address(0)) revert NoWithdrawalQueuedForCCTP();

        SafeData memory data = cashModule.getData(safe);
        if (data.pendingWithdrawalRequest.recipient == address(this)) cashModule.cancelWithdrawalByModule(safe);

        emit BridgeCancelled(safe, w.destDomain, w.asset, w.amount, w.destRecipient);
        delete _getCCTPModuleStorage().withdrawals[safe];
    }

    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != etherFiDataProvider.getCashModule()) revert Unauthorized();

        CrossChainWithdrawal storage w = _getCCTPModuleStorage().withdrawals[safe];
        if (w.destRecipient == address(0)) return;

        emit BridgeCancelled(safe, w.destDomain, w.asset, w.amount, w.destRecipient);
        delete _getCCTPModuleStorage().withdrawals[safe];
    }

    function _bridge(address safe, CrossChainWithdrawal memory w) internal {
        _checkBalance(w.asset, w.amount);
        if (w.tokenMessenger == address(0)) revert UnsupportedAsset();

        if (w.etherFiFee > 0) {
            // Recipient snapshotted at request-time; a mid-flight setEtherFiFeeRecipient(0) cannot redirect it.
            if (w.etherFiFeeRecipient == address(0)) revert EtherFiFeeRecipientNotSet();
            IERC20(w.asset).safeTransfer(w.etherFiFeeRecipient, w.etherFiFee);
            emit EtherFiFeeCharged(safe, w.asset, w.etherFiFee, w.etherFiFeeRecipient);
        }

        uint256 burnAmount = w.amount - w.etherFiFee;
        bytes32 mintRecipient = bytes32(uint256(uint160(w.destRecipient)));

        IERC20(w.asset).forceApprove(w.tokenMessenger, burnAmount);
        ICCTPTokenMessenger(w.tokenMessenger).depositForBurn(
            burnAmount,
            w.destDomain,
            mintRecipient,
            w.asset,
            bytes32(0),
            w.maxFee,
            w.minFinalityThreshold
        );

        emit BridgeWithCCTP(safe, w.destDomain, w.asset, w.amount, burnAmount, mintRecipient, w.tokenMessenger, w.maxFee, w.minFinalityThreshold, w.etherFiFee);
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
            // Only validate fee/finality for *supported* assets (tokenMessenger != 0).
            // A zero tokenMessenger is the "remove/unsupported" sentinel and skips validation.
            if (cfg.tokenMessenger != address(0)) {
                if (cfg.finalityThreshold != FINALITY_CONFIRMED && cfg.finalityThreshold != FINALITY_FINALIZED) revert InvalidFinalityThreshold();
                // Standard (Finalized) transfers are free on every chain this module sources from
                // (no Standard-fee-switch on OP's TokenMessengerV2 per Circle docs), so a non-zero
                // fee paired with Standard finality is always meaningless/misleading — reject it.
                if (cfg.finalityThreshold == FINALITY_FINALIZED && cfg.maxFeeBps != 0) revert StandardModeFeeNotAllowed();
                if (cfg.maxFeeBps > MAX_FEE_BPS) revert MaxFeeBpsTooHigh();
                if (cfg.etherFiFeeBps > MAX_FEE_BPS) revert EtherFiFeeBpsTooHigh();
            }
            $.assetConfig[assets[i]] = cfg;
            unchecked { ++i; }
        }
        emit AssetConfigSet(assets, assetConfigs);
    }

    function _checkBalance(address asset, uint256 amount) internal view {
        if (IERC20(asset).balanceOf(address(this)) < amount) revert InsufficientAmount();
    }
}
