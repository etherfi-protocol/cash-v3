// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {OneInchSwapDescription} from "../../interfaces/IOneInch.sol";
import {IEtherFiSafe} from "../../interfaces/IEtherFiSafe.sol";
import {IBridgeModule} from "../../interfaces/IBridgeModule.sol";
import {ModuleBase} from "../ModuleBase.sol";
import {ModuleCheckBalance} from "../ModuleCheckBalance.sol";

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
 *      Multi-step async flow. The Safe is the "maker" in a 1inch Fusion order.
 *      Tokens never leave the Safe — the Safe approves the 1inch router and implements ERC-1271
 *      (via authorizeOrderHash) so the Limit Order Protocol can verify the order and the resolver
 *      can pull tokens directly from the Safe via transferFrom.
 *      Entry points: requestSwap() -> executeSwap() -> settleSwap()
 *
 *      Both modes use the same 1inch Aggregation Router.
 */
contract OneInchSwapModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient, IBridgeModule {
    using MessageHashUtils for bytes32;

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
    //  Signature type hashes
    // ──────────────────────────────────────────────

    /// @notice Classic swap signature type hash
    bytes32 public constant SWAP_SIG = keccak256("swap");

    /// @notice Fusion: request swap signature type hash
    bytes32 public constant REQUEST_SWAP_SIG = keccak256("requestSwap");

    /// @notice Fusion: execute swap signature type hash
    bytes32 public constant EXECUTE_SWAP_SIG = keccak256("executeSwap");

    /// @notice Fusion: settle swap signature type hash
    bytes32 public constant SETTLE_SWAP_SIG = keccak256("settleSwap");

    /// @notice Fusion: cancel swap signature type hash
    bytes32 public constant CANCEL_SWAP_SIG = keccak256("cancelSwap");

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted on a successful classic (DEX) swap
    event ClassicSwap(
        address indexed safe,
        address indexed fromAsset,
        address indexed toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        uint256 returnAmount
    );

    /// @notice Emitted when a Fusion swap is requested (intent recorded)
    event FusionSwapRequested(
        address indexed safe,
        address indexed fromToken,
        address indexed toToken,
        uint256 fromAmount,
        uint256 minToAmount
    );

    /// @notice Emitted when a Fusion swap is executed (order authorized on Safe)
    event FusionSwapExecuted(address indexed safe, bytes32 indexed orderHash);

    /// @notice Emitted when a Fusion swap is settled after fill
    event FusionSwapSettled(
        address indexed safe,
        address indexed fromToken,
        address indexed toToken,
        uint256 fromAmount,
        uint256 receivedAmount
    );

    /// @notice Emitted when a Fusion swap is cancelled
    event FusionSwapCancelled(address indexed safe, address indexed fromToken);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error SwappingToSameAsset();
    error InvalidSignatures();
    error OutputLessThanMinAmount();
    error SlippageTooHigh();
    error NoPendingSwap();
    error SwapAlreadyPending();
    error SwapAlreadyExecuted();
    error SwapNotExecuted();
    error InsufficientReceivedAmount();
    error OrderNotFilled();
    error NativeETHNotSupported();
    error Unauthorized();

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    /**
     * @param _aggregationRouter 1inch Aggregation Router address
     * @param _dataProvider EtherFi data provider address
     */
    constructor(
        address _aggregationRouter,
        address _dataProvider
    ) ModuleBase(_dataProvider) ModuleCheckBalance(_dataProvider) {
        if (_aggregationRouter == address(0)) revert InvalidInput();
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
    function swap(
        address safe,
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        bytes calldata data,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external nonReentrant onlyEtherFiSafe(safe) {
        _checkSignatures(SWAP_SIG, safe, abi.encode(fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data), signers, signatures);
        _classicSwap(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data);
    }

    // ══════════════════════════════════════════════
    //  FUSION (RFQ / INTENT) SWAP — Safe-as-Maker
    // ══════════════════════════════════════════════

    /**
     * @notice Initiates a Fusion swap by recording the swap intent
     * @dev No tokens are moved. The Safe's balance is checked for availability.
     *      The backend will later call executeSwap() with the 1inch order hash.
     * @param safe Address of the EtherFi Safe
     * @param fromToken Token to sell
     * @param toToken Token to buy
     * @param fromAmount Amount of fromToken to sell
     * @param minToAmount Minimum amount of toToken expected after fill
     * @param signers Safe owner addresses authorizing this swap
     * @param signatures Signatures from the signers
     */
    function requestSwap(
        address safe,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minToAmount,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external onlyEtherFiSafe(safe) {
        if (fromToken == ETH || toToken == ETH) revert NativeETHNotSupported();
        if (fromToken == toToken) revert SwappingToSameAsset();
        if (fromAmount == 0 || minToAmount == 0) revert InvalidInput();
        if (pendingSwaps[safe].fromAmount != 0) revert SwapAlreadyPending();

        _checkSignatures(REQUEST_SWAP_SIG, safe, abi.encode(fromToken, toToken, fromAmount, minToAmount), signers, signatures);
        _checkAmountAvailable(safe, fromToken, fromAmount);

        pendingSwaps[safe] = PendingSwap({
            fromToken: fromToken,
            toToken: toToken,
            fromAmount: fromAmount,
            minToAmount: minToAmount,
            orderHash: bytes32(0),
            fromBalanceBefore: 0,
            toBalanceBefore: 0
        });

        emit FusionSwapRequested(safe, fromToken, toToken, fromAmount, minToAmount);
    }

    /**
     * @notice Activates the Fusion swap: Safe approves the router and authorizes the order hash
     * @dev Called by backend once the 1inch order is constructed.
     *      The Safe approves the aggregation router for fromAmount and registers the orderHash
     *      on the Safe for ERC-1271 validation. The resolver can then fill via transferFrom on the Safe.
     * @param safe Address of the EtherFi Safe
     * @param orderHash The 1inch order hash (precomputed by backend)
     * @param signers Safe owner addresses authorizing execution
     * @param signatures Signatures from the signers
     */
    function executeSwap(
        address safe,
        bytes32 orderHash,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external nonReentrant onlyEtherFiSafe(safe) {
        PendingSwap storage pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();
        if (pendingSwap.orderHash != bytes32(0)) revert SwapAlreadyExecuted();
        if (orderHash == bytes32(0)) revert InvalidInput();

        _checkSignatures(EXECUTE_SWAP_SIG, safe, abi.encode(orderHash), signers, signatures);

        // Snapshot balances before the fill
        pendingSwap.fromBalanceBefore = IERC20(pendingSwap.fromToken).balanceOf(safe);
        pendingSwap.toBalanceBefore = IERC20(pendingSwap.toToken).balanceOf(safe);
        pendingSwap.orderHash = orderHash;

        // Safe approves router to pull fromTokens
        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = pendingSwap.fromToken;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, aggregationRouter, pendingSwap.fromAmount);
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        // Authorize order hash on Safe for ERC-1271 validation
        IEtherFiSafe(safe).authorizeOrderHash(orderHash);

        emit FusionSwapExecuted(safe, orderHash);
    }

    /**
     * @notice Finalizes the Fusion swap after the 1inch order has been filled
     * @dev Called by backend once the order fill is confirmed on-chain.
     *      Verifies that the Safe's fromToken balance decreased (order filled) and
     *      the Safe received at least minToAmount of toToken since executeSwap.
     * @param safe Address of the EtherFi Safe
     * @param signers Safe owner addresses authorizing settlement
     * @param signatures Signatures from the signers
     */
    function settleSwap(
        address safe,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external nonReentrant onlyEtherFiSafe(safe) {
        PendingSwap memory pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();
        if (pendingSwap.orderHash == bytes32(0)) revert SwapNotExecuted();

        _checkSignatures(SETTLE_SWAP_SIG, safe, "", signers, signatures);

        // Verify the order was filled: Safe's fromToken balance must have decreased
        uint256 currentFromBalance = IERC20(pendingSwap.fromToken).balanceOf(safe);
        if (currentFromBalance >= pendingSwap.fromBalanceBefore) revert OrderNotFilled();

        // Verify the Safe received enough toToken since executeSwap
        uint256 currentToBalance = IERC20(pendingSwap.toToken).balanceOf(safe);
        uint256 received = currentToBalance - pendingSwap.toBalanceBefore;
        if (received < pendingSwap.minToAmount) revert InsufficientReceivedAmount();

        // Revoke router approval and order hash on Safe
        _revokeApprovalAndOrderHash(safe, pendingSwap.fromToken, pendingSwap.orderHash);

        delete pendingSwaps[safe];

        emit FusionSwapSettled(safe, pendingSwap.fromToken, pendingSwap.toToken, pendingSwap.fromAmount, received);
    }

    /**
     * @notice Cancels a pending Fusion swap at any stage before settlement
     * @dev If executeSwap was called, revokes the router approval and order hash on the Safe.
     *      Tokens remain on the Safe throughout — nothing to transfer back.
     * @param safe Address of the EtherFi Safe
     * @param signers Safe owner addresses authorizing cancellation
     * @param signatures Signatures from the signers
     */
    function cancelSwap(
        address safe,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external nonReentrant onlyEtherFiSafe(safe) {
        PendingSwap memory pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();

        _checkSignatures(CANCEL_SWAP_SIG, safe, "", signers, signatures);

        if (pendingSwap.orderHash != bytes32(0)) {
            _revokeApprovalAndOrderHash(safe, pendingSwap.fromToken, pendingSwap.orderHash);
        }

        delete pendingSwaps[safe];

        emit FusionSwapCancelled(safe, pendingSwap.fromToken);
    }

    // ──────────────────────────────────────────────
    //  IBridgeModule (called by CashModule for force-cancellation)
    // ──────────────────────────────────────────────

    /**
     * @notice Called by CashModule to force-cancel a pending swap (e.g. during liquidation)
     * @dev Revokes any active approval and order hash on the Safe, then cleans up state.
     * @param safe Address of the EtherFi Safe
     */
    function cancelBridgeByCashModule(address safe) external nonReentrant {
        if (msg.sender != etherFiDataProvider.getCashModule()) revert Unauthorized();

        PendingSwap memory pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) return;

        if (pendingSwap.orderHash != bytes32(0)) {
            _revokeApprovalAndOrderHash(safe, pendingSwap.fromToken, pendingSwap.orderHash);
        }

        delete pendingSwaps[safe];
        emit FusionSwapCancelled(safe, pendingSwap.fromToken);
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

    function _classicSwap(
        address safe,
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        bytes calldata data
    ) internal {
        if (fromAsset == toAsset) revert SwappingToSameAsset();
        if (minToAssetAmount == 0) revert InvalidInput();

        _checkAmountAvailable(safe, fromAsset, fromAssetAmount);
        _validateClassicSwapData(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data);

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

    function _classicSwapERC20(
        address fromAsset,
        uint256 fromAssetAmount,
        bytes calldata data
    ) internal view returns (address[] memory to, uint256[] memory value, bytes[] memory callData) {
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

    function _classicSwapNative(
        uint256 fromAssetAmount,
        bytes calldata data
    ) internal view returns (address[] memory to, uint256[] memory value, bytes[] memory callData) {
        to = new address[](1);
        value = new uint256[](1);
        callData = new bytes[](1);

        to[0] = aggregationRouter;
        value[0] = fromAssetAmount;
        callData[0] = data;
    }

    /**
     * @notice Validates the 1inch classic swap calldata when the selector matches swap()
     * @dev Decodes the SwapDescription from the 1inch router's swap() function and validates
     *      that the parameters match what was signed by the Safe owners.
     *      Selector 0x12aa3caf = swap(address,(address,address,address,address,uint256,uint256,uint256),bytes,bytes)
     *      For other 1inch router functions (unoswapTo, etc.), the balance check in _classicSwap provides safety.
     */
    function _validateClassicSwapData(
        address safe,
        address fromAsset,
        address toAsset,
        uint256 fromAssetAmount,
        uint256 minToAssetAmount,
        bytes calldata data
    ) internal pure {
        if (data.length >= 4 && bytes4(data[:4]) == bytes4(0x12aa3caf)) {
            (, OneInchSwapDescription memory desc,,) = abi.decode(data[4:], (address, OneInchSwapDescription, bytes, bytes));

            if (
                address(desc.srcToken) != fromAsset ||
                address(desc.dstToken) != toAsset ||
                desc.dstReceiver != payable(safe) ||
                desc.amount != fromAssetAmount
            ) revert InvalidInput();

            if (desc.minReturnAmount < minToAssetAmount) revert SlippageTooHigh();
        }
    }

    // ══════════════════════════════════════════════
    //  INTERNAL: Fusion Helpers
    // ══════════════════════════════════════════════

    /**
     * @dev Revokes the router's approval and the order hash on the Safe
     */
    function _revokeApprovalAndOrderHash(address safe, address fromToken, bytes32 orderHash) internal {
        // Revoke router approval
        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = fromToken;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, aggregationRouter, 0);
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        // Revoke order hash on Safe
        IEtherFiSafe(safe).revokeOrderHash(orderHash);
    }

    // ══════════════════════════════════════════════
    //  INTERNAL: Signature Verification
    // ══════════════════════════════════════════════

    function _checkSignatures(
        bytes32 selector,
        address safe,
        bytes memory data,
        address[] calldata signers,
        bytes[] calldata signatures
    ) internal {
        bytes32 digestHash = keccak256(abi.encodePacked(
            selector,
            block.chainid,
            address(this),
            IEtherFiSafe(safe).useNonce(),
            safe,
            data
        )).toEthSignedMessageHash();

        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }
}
