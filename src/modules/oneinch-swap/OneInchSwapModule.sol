// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IBridgeModule } from "../../interfaces/IBridgeModule.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";

/**
 * @title OneInchSwapModule
 * @author ether.fi
 * @notice Module for executing token swaps through 1inch — supports both Classic (DEX) and Fusion (RFQ) modes
 *
 * @dev Classic (DEX aggregation):
 *      Single atomic transaction. Safe approves router, router swaps via DEXes, module verifies output.
 *      Tokens never leave the Safe. Same pattern as OpenOceanSwapModule.
 *      Entry point: swap()
 *
 *      Fusion (intent-based / RFQ):
 *      Two-step async flow. The Safe is the "maker" in a 1inch Fusion order.
 *      Tokens never leave the Safe — requestSwap() records the intent, registers a pending
 *      withdrawal with CashModule (preempted by card spend via cancelBridgeByCashModule),
 *      and approves the 1inch router. The 1inch Limit Order Protocol validates the order via
 *      EtherFiSafe.isValidSignature (direct multi-owner verification), then the resolver
 *      pulls fromToken via transferFrom. settleSwap() finalizes once the fill lands.
 *      Entry points: requestSwap() -> settleSwap() (or cancelSwap() to abort)
 *
 *      Both modes use the same 1inch Aggregation Router.
 */
contract OneInchSwapModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient, IBridgeModule {
    // ──────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────

    /// @notice State of a pending Fusion swap for a Safe
    struct PendingSwap {
        address fromToken;
        address toToken;
        uint256 fromAmount;
        uint256 minToAmount;
        bytes32 orderHash;
        uint256 fromBalanceBefore;
        uint256 toBalanceBefore;
    }

    // ──────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────

    /// @notice 1inch Aggregation Router address (shared by Classic and Fusion)
    address public immutable aggregationRouter;

    // ──────────────────────────────────────────────
    //  State (Fusion only)
    // ──────────────────────────────────────────────

    /// @notice Pending Fusion swap per Safe (only one at a time)
    mapping(address safe => PendingSwap) public pendingSwaps;

    // ──────────────────────────────────────────────
    //  EIP-712 type hashes (unified with EtherFiSafe's signing scheme)
    // ──────────────────────────────────────────────

    /// @notice Classic (DEX aggregation) swap typehash
    bytes32 public constant SWAP_TYPEHASH = keccak256("ClassicSwap(address safe,address fromAsset,address toAsset,uint256 fromAssetAmount,uint256 minToAssetAmount,bytes data,uint256 nonce)");

    /// @notice Fusion: request swap typehash
    bytes32 public constant REQUEST_SWAP_TYPEHASH = keccak256("RequestSwap(address safe,address fromToken,address toToken,uint256 fromAmount,uint256 minToAmount,bytes32 orderHash,uint256 nonce)");

    /// @notice Fusion: cancel swap typehash
    bytes32 public constant CANCEL_SWAP_TYPEHASH = keccak256("CancelSwap(address safe,uint256 nonce)");

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted on a successful classic (DEX) swap
    event ClassicSwap(address indexed safe, address indexed fromAsset, address indexed toAsset, uint256 fromAssetAmount, uint256 minToAssetAmount, uint256 returnAmount);

    /// @notice Emitted when a Fusion swap is requested (intent recorded, router approved)
    event FusionSwapRequested(address indexed safe, address indexed fromToken, address indexed toToken, uint256 fromAmount, uint256 minToAmount, bytes32 orderHash);

    /// @notice Emitted when a Fusion swap is settled after fill
    event FusionSwapSettled(address indexed safe, address indexed fromToken, address indexed toToken, uint256 fromAmount, uint256 receivedAmount);

    /// @notice Emitted when a Fusion swap is cancelled
    event FusionSwapCancelled(address indexed safe, address indexed fromToken, bytes32 indexed orderHash);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error SwappingToSameAsset();
    error InvalidSignatures();
    error OutputLessThanMinAmount();
    error NoPendingSwap();
    error SwapAlreadyPending();
    error InsufficientReceivedAmount();
    error OrderNotFilled();
    error UnexpectedFromBalance();
    error NativeETHNotSupported();
    error Unauthorized();

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    /**
     * @param _aggregationRouter 1inch Aggregation Router address
     * @param _dataProvider EtherFi data provider address
     */
    constructor(address _aggregationRouter, address _dataProvider) ModuleBase(_dataProvider) ModuleCheckBalance(_dataProvider) {
        if (_aggregationRouter == address(0) || _aggregationRouter.code.length == 0) revert InvalidInput();
        aggregationRouter = _aggregationRouter;
    }

    // ══════════════════════════════════════════════
    //  CLASSIC (DEX) SWAP
    // ══════════════════════════════════════════════

    /**
     * @notice Executes an atomic token swap through 1inch DEX aggregation
     * @dev Tokens never leave the Safe. The Safe approves the router, router executes the swap,
     *      module verifies the output, and approval is revoked. Same pattern as OpenOceanSwapModule.
     * @param safe Address of the EtherFi Safe
     * @param fromAsset Token to sell (or ETH address for native)
     * @param toAsset Token to buy (or ETH address for native)
     * @param fromAssetAmount Amount of fromAsset to sell
     * @param minToAssetAmount Minimum amount of toAsset to receive
     * @param data Raw 1inch router calldata (from 1inch Swap API)
     * @param signers Safe owner addresses authorizing this swap
     * @param signatures Signatures from the signers
     */
    function swap(address safe, address fromAsset, address toAsset, uint256 fromAssetAmount, uint256 minToAssetAmount, bytes calldata data, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        _verifyClassicSwap(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data, signers, signatures);
        _classicSwap(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data);
    }

    /// @dev Extracted to break stack pressure in `requestSwap()`.
    function _verifyRequestSwap(address safe, address fromToken, address toToken, uint256 fromAmount, uint256 minToAmount, bytes32 orderHash, address[] calldata signers, bytes[] calldata signatures) internal {
        uint256 nonce_ = IEtherFiSafe(safe).useNonce();
        bytes32 structHash = keccak256(abi.encode(REQUEST_SWAP_TYPEHASH, safe, fromToken, toToken, fromAmount, minToAmount, orderHash, nonce_));
        _verifyStructHash(safe, structHash, signers, signatures);
    }

    /// @dev Extracted to break stack pressure in `swap()`.
    function _verifyClassicSwap(address safe, address fromAsset, address toAsset, uint256 fromAssetAmount, uint256 minToAssetAmount, bytes calldata data, address[] calldata signers, bytes[] calldata signatures) internal {
        uint256 nonce_ = IEtherFiSafe(safe).useNonce();
        bytes32 dataHash = keccak256(data);
        bytes32 structHash = keccak256(abi.encode(SWAP_TYPEHASH, safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, dataHash, nonce_));
        _verifyStructHash(safe, structHash, signers, signatures);
    }

    // ══════════════════════════════════════════════
    //  FUSION (RFQ / INTENT) SWAP — Safe-as-Maker
    // ══════════════════════════════════════════════

    /**
     * @notice Opens a Fusion swap: records intent, registers pending withdrawal, approves router
     * @dev Atomically:
     *      1. verifies Safe-owner quorum over (fromToken, toToken, fromAmount, minToAmount, orderHash)
     *      2. calls CashModule.requestWithdrawalByModule — card spend can preempt via
     *         cancelByCashModule, which revokes the router approval and deletes state
     *      3. snapshots balances and approves the 1inch router for fromAmount
     *      The 1inch Limit Order Protocol validates the order against the Safe's
     *      isValidSignature (direct multi-owner verification); no orderHash whitelisting is needed.
     * @param safe Address of the EtherFi Safe
     * @param fromToken Token to sell
     * @param toToken Token to buy
     * @param fromAmount Amount of fromToken to sell
     * @param minToAmount Minimum amount of toToken expected after fill (net of 1inch fee)
     * @param orderHash The 1inch order hash (precomputed by backend, covered by signatures)
     * @param signers Safe owner addresses authorizing this swap
     * @param signatures Signatures from the signers
     */
    function requestSwap(address safe, address fromToken, address toToken, uint256 fromAmount, uint256 minToAmount, bytes32 orderHash, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        if (fromToken == ETH || toToken == ETH) revert NativeETHNotSupported();
        if (fromToken == toToken) revert SwappingToSameAsset();
        if (fromAmount == 0 || minToAmount == 0 || orderHash == bytes32(0)) revert InvalidInput();
        if (pendingSwaps[safe].fromAmount != 0) revert SwapAlreadyPending();

        _verifyRequestSwap(safe, fromToken, toToken, fromAmount, minToAmount, orderHash, signers, signatures);
        _checkAmountAvailable(safe, fromToken, fromAmount);

        // Register a pending withdrawal on CashModule so card spend can preempt via cancelBridgeByCashModule
        cashModule.requestWithdrawalByModule(safe, fromToken, fromAmount);

        pendingSwaps[safe] = PendingSwap({ fromToken: fromToken, toToken: toToken, fromAmount: fromAmount, minToAmount: minToAmount, orderHash: orderHash, fromBalanceBefore: IERC20(fromToken).balanceOf(safe), toBalanceBefore: IERC20(toToken).balanceOf(safe) });

        // Safe approves router to pull fromTokens
        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = fromToken;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, aggregationRouter, fromAmount);
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        emit FusionSwapRequested(safe, fromToken, toToken, fromAmount, minToAmount, orderHash);
    }

    /**
     * @notice Finalizes the Fusion swap after the 1inch order has been filled
     * @dev Callable only by Safe admins (single admin suffices — no quorum). The correctness
     *      gates are post-hoc: fromToken balance must have decreased (OrderNotFilled check)
     *      and toToken balance must have increased by at least minToAmount (set at request
     *      time under full owner quorum). No partial fills per design, so a premature settle
     *      cannot truncate remaining fills.
     *      Releases the pending withdrawal on CashModule and revokes the router approval.
     * @param safe Address of the EtherFi Safe
     */
    function settleSwap(address safe) external nonReentrant onlyEtherFiSafe(safe) {
        if (!IEtherFiSafe(safe).isAdmin(msg.sender)) revert Unauthorized();

        PendingSwap memory pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();

        // No partial fills by design — fromToken balance must have dropped by exactly fromAmount.
        // A strict equality (vs. "any decrease") defends against future modules that also
        // move fromToken behind our back from silently satisfying this check.
        uint256 currentFromBalance = IERC20(pendingSwap.fromToken).balanceOf(safe);
        if (currentFromBalance > pendingSwap.fromBalanceBefore - pendingSwap.fromAmount) revert OrderNotFilled();
        if (currentFromBalance < pendingSwap.fromBalanceBefore - pendingSwap.fromAmount) revert UnexpectedFromBalance();

        // Verify the Safe received enough toToken since requestSwap
        uint256 currentToBalance = IERC20(pendingSwap.toToken).balanceOf(safe);
        uint256 received = currentToBalance - pendingSwap.toBalanceBefore;
        if (received < pendingSwap.minToAmount) revert InsufficientReceivedAmount();

        _revokeApproval(safe, pendingSwap.fromToken);

        // Delete local state BEFORE releasing the CashModule withdrawal. cancelWithdrawalByModule
        // triggers _cancelOldWithdrawal → IBridgeModule(this).cancelBridgeByCashModule(safe) as a
        // callback; with fromAmount already zero, the callback short-circuits (no duplicate event,
        // no redundant approval revoke).
        delete pendingSwaps[safe];
        cashModule.cancelWithdrawalByModule(safe);

        emit FusionSwapSettled(safe, pendingSwap.fromToken, pendingSwap.toToken, pendingSwap.fromAmount, received);
    }

    /**
     * @notice Cancels a pending Fusion swap before settlement
     * @dev Revokes the router approval and releases the pending withdrawal on CashModule.
     *      Tokens remain on the Safe throughout — nothing to transfer back.
     * @param safe Address of the EtherFi Safe
     * @param signers Safe owner addresses authorizing cancellation
     * @param signatures Signatures from the signers
     */
    function cancelSwap(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        PendingSwap memory pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();

        bytes32 structHash = keccak256(abi.encode(CANCEL_SWAP_TYPEHASH, safe, IEtherFiSafe(safe).useNonce()));
        _verifyStructHash(safe, structHash, signers, signatures);

        _revokeApproval(safe, pendingSwap.fromToken);

        // Delete before releasing the CashModule withdrawal (callback short-circuits — see settleSwap)
        delete pendingSwaps[safe];
        cashModule.cancelWithdrawalByModule(safe);

        emit FusionSwapCancelled(safe, pendingSwap.fromToken, pendingSwap.orderHash);
    }

    // ──────────────────────────────────────────────
    //  IBridgeModule (called by CashModule for force-cancellation)
    // ──────────────────────────────────────────────

    /**
     * @notice Called by CashModule to force-cancel a pending swap (e.g. card spend preemption, liquidation)
     * @dev Revokes router approval and cleans up state. Does NOT call cancelWithdrawalByModule
     *      since CashModule is already inside _cancelOldWithdrawal when we are invoked.
     *      No nonReentrant: the sole legitimate caller is CashModule (msg.sender check below),
     *      and this function is also re-entered via cancelWithdrawalByModule from our own
     *      settleSwap/cancelSwap — adding nonReentrant would clash with those guards.
     * @param safe Address of the EtherFi Safe
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != etherFiDataProvider.getCashModule()) revert Unauthorized();

        PendingSwap memory pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) return;

        delete pendingSwaps[safe];
        _revokeApproval(safe, pendingSwap.fromToken);

        emit FusionSwapCancelled(safe, pendingSwap.fromToken, pendingSwap.orderHash);
    }

    // ──────────────────────────────────────────────
    //  View Functions
    // ──────────────────────────────────────────────

    /**
     * @notice Returns the pending Fusion swap details for a Safe
     * @param safe Address of the EtherFi Safe
     * @return The PendingSwap struct
     */
    function getPendingSwap(address safe) external view returns (PendingSwap memory) {
        return pendingSwaps[safe];
    }

    // ══════════════════════════════════════════════
    //  INTERNAL: Classic Swap Logic
    // ══════════════════════════════════════════════

    function _classicSwap(address safe, address fromAsset, address toAsset, uint256 fromAssetAmount, uint256 minToAssetAmount, bytes calldata data) internal {
        if (fromAsset == toAsset) revert SwappingToSameAsset();
        if (minToAssetAmount == 0) revert InvalidInput();

        _checkAmountAvailable(safe, fromAsset, fromAssetAmount);

        uint256 balBefore;
        if (toAsset == ETH) balBefore = address(safe).balance;
        else balBefore = IERC20(toAsset).balanceOf(safe);

        address[] memory to;
        uint256[] memory value;
        bytes[] memory callData;
        if (fromAsset == ETH) (to, value, callData) = _classicSwapNative(fromAssetAmount, data);
        else (to, value, callData) = _classicSwapERC20(fromAsset, fromAssetAmount, data);

        IEtherFiSafe(safe).execTransactionFromModule(to, value, callData);

        uint256 balAfter;
        if (toAsset == ETH) balAfter = address(safe).balance;
        else balAfter = IERC20(toAsset).balanceOf(safe);

        uint256 receivedAmt = balAfter - balBefore;
        if (receivedAmt < minToAssetAmount) revert OutputLessThanMinAmount();

        emit ClassicSwap(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, receivedAmt);
    }

    function _classicSwapERC20(address fromAsset, uint256 fromAssetAmount, bytes calldata data) internal view returns (address[] memory to, uint256[] memory value, bytes[] memory callData) {
        to = new address[](3);
        value = new uint256[](3);
        callData = new bytes[](3);

        to[0] = fromAsset;
        callData[0] = abi.encodeWithSelector(IERC20.approve.selector, aggregationRouter, fromAssetAmount);

        to[1] = aggregationRouter;
        callData[1] = data;

        to[2] = fromAsset;
        callData[2] = abi.encodeWithSelector(IERC20.approve.selector, aggregationRouter, 0);
    }

    function _classicSwapNative(uint256 fromAssetAmount, bytes calldata data) internal view returns (address[] memory to, uint256[] memory value, bytes[] memory callData) {
        to = new address[](1);
        value = new uint256[](1);
        callData = new bytes[](1);

        to[0] = aggregationRouter;
        value[0] = fromAssetAmount;
        callData[0] = data;
    }

    // ══════════════════════════════════════════════
    //  INTERNAL: Fusion Helpers
    // ══════════════════════════════════════════════

    /**
     * @dev Revokes the router's fromToken approval on the Safe
     */
    function _revokeApproval(address safe, address fromToken) internal {
        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = fromToken;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, aggregationRouter, 0);
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    // ══════════════════════════════════════════════
    //  INTERNAL: EIP-712 Signature Verification
    // ══════════════════════════════════════════════

    /**
     * @dev Verifies an EIP-712 structured signature under the Safe's domain.
     *      Caller computes `structHash` from the appropriate TYPEHASH + fields + fresh nonce.
     */
    function _verifyStructHash(address safe, bytes32 structHash, address[] calldata signers, bytes[] calldata signatures) internal view {
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", IEtherFiSafe(safe).getDomainSeparator(), structHash));
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }
}
