// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IOrderMixin } from "@1inch/limit-order-protocol-contract/contracts/interfaces/IOrderMixin.sol";
import { IPreInteraction } from "@1inch/limit-order-protocol-contract/contracts/interfaces/IPreInteraction.sol";
import { MakerTraits } from "@1inch/limit-order-protocol-contract/contracts/libraries/MakerTraitsLib.sol";
import { Address, AddressLib } from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";

import { IBridgeModule } from "../../interfaces/IBridgeModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ISwapInteractionInterface } from "../../interfaces/ISwapInteractionInterface.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";

/**
 * @title OneInchSwapModule
 * @author ether.fi
 * @notice Module for executing token swaps through 1inch — supports both Classic (DEX) and Fusion (RFQ) modes.
 *
 * @dev Classic (DEX aggregation): single atomic transaction. The Safe approves the router, the
 *      router swaps via DEXes, the module verifies the output, and the approval is revoked.
 *      Tokens never leave the Safe. Entry point: `swap()`.
 *
 *      Fusion (intent-based / RFQ): two-step async flow. The Safe is the maker in a 1inch
 *      Limit Order Protocol order. `requestSwap()` records the intent, constructs the LOP
 *      order on-chain with a fixed extension that pins PRE_INTERACTION and POST_INTERACTION
 *      callbacks to this module, registers a pending withdrawal with CashModule, and approves
 *      the 1inch router. Authorization at fill time goes through `EtherFiSafe.isValidSignature`,
 *      which is bound to the on-chain `pendingSwaps` entry — only the exact orderHash
 *      registered by `requestSwap` can be filled. `preInteraction()` validates the live order
 *      against the registered intent; `postInteraction()` settles balances, revokes the
 *      approval, releases the CashModule withdrawal, and asserts solvency. Entry points:
 *      `requestSwap() -> {preInteraction(), postInteraction()}` (or `cancelSwap()` to abort).
 */
contract OneInchSwapModule is ModuleBase, ModuleCheckBalance, ReentrancyGuardTransient, IBridgeModule, ISwapInteractionInterface, IPreInteraction {
    using AddressLib for Address;

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
    }

    // ──────────────────────────────────────────────
    //  Immutables
    // ──────────────────────────────────────────────

    /// @notice 1inch Aggregation Router address (shared by Classic and Fusion)
    address public immutable aggregationRouter;

    /// @notice Role identifier required to call `recoverStuckMakerTokens`. Shares the same hash
    ///         as `EtherFiDataProvider.DATA_PROVIDER_ADMIN_ROLE`.
    bytes32 public constant DATA_PROVIDER_ADMIN_ROLE = keccak256("DATA_PROVIDER_ADMIN_ROLE");

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    /// @notice Pending Fusion swap per Safe (only one at a time)
    mapping(address safe => PendingSwap) public pendingSwaps;

    /// @notice True for the lifetime of an open Fusion intent (set in `requestSwap`, cleared on
    ///         settle / cancel / preempt) or for the duration of a classic `swap()` call.
    ///         `DebtManager.liquidate` reverts when this is set, so a third party cannot
    ///         liquidate a Safe while it has an in-flight order.
    mapping(address safe => bool) public swapInProgress;

    // ──────────────────────────────────────────────
    //  EIP-712 type hashes (unified with EtherFiSafe's signing scheme)
    // ──────────────────────────────────────────────

    /// @notice Classic (DEX aggregation) swap typehash. The `module` field binds the signature
    ///         to this contract so it cannot be replayed against a different module sharing the
    ///         Safe's domain separator.
    bytes32 public constant SWAP_TYPEHASH = keccak256("ClassicSwap(address safe,address module,address fromAsset,address toAsset,uint256 fromAssetAmount,uint256 minToAssetAmount,bytes data,uint256 nonce)");

    /// @notice Fusion request typehash — owners sign over the swap intent + expiration. The
    ///         orderHash is derived from these fields on-chain, so no separate orderHash
    ///         signature is needed. `module` binds the signature to this contract.
    bytes32 public constant REQUEST_SWAP_TYPEHASH = keccak256("RequestSwap(address safe,address module,address fromToken,address toToken,uint256 fromAmount,uint256 minToAmount,uint40 expiration,uint256 nonce)");

    /// @notice Fusion cancel typehash. `module` binds the signature to this contract.
    bytes32 public constant CANCEL_SWAP_TYPEHASH = keccak256("CancelSwap(address safe,address module,uint256 nonce)");

    // ──────────────────────────────────────────────
    //  1inch order construction constants
    // ──────────────────────────────────────────────

    /// @dev MakerTraits flag bit positions (from MakerTraitsLib).
    uint256 private constant _NO_PARTIAL_FILLS_FLAG = 1 << 255;
    uint256 private constant _PRE_INTERACTION_CALL_FLAG = 1 << 252;
    uint256 private constant _POST_INTERACTION_CALL_FLAG = 1 << 251;
    uint256 private constant _HAS_EXTENSION_FLAG = 1 << 249;

    /// @dev Bit offset of the uint40 expiration field within MakerTraits.
    uint256 private constant _EXPIRATION_OFFSET = 80;

    /// @dev Bit offset of the uint40 nonceOrEpoch field within MakerTraits. With NO_PARTIAL_FILLS,
    ///      LOP's `useBitInvalidator()` is true and the per-fill bit lives at
    ///      `_bitInvalidator[maker]._raw[nonceOrEpoch >> 8]` bit `nonceOrEpoch & 0xff`. The safe
    ///      nonce (lower 40 bits) is packed here so every order from a given Safe targets a
    ///      distinct invalidator cell — otherwise the second fill from any Safe would revert
    ///      with `BitInvalidatedOrder()`.
    uint256 private constant _NONCE_OR_EPOCH_OFFSET = 120;

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

    /// @notice Emitted when admin recovers maker tokens stuck at the module address after a misconfigured request
    event FusionSwapRecovered(address indexed safe, address indexed fromToken, uint256 amount, bytes32 orderHash);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error SwappingToSameAsset();
    error InvalidSignatures();
    error OutputLessThanMinAmount();
    error NoPendingSwap();
    error SwapAlreadyPending();
    error InsufficientReceivedAmount();
    error OrderHashMismatch();
    error OrderTokenMismatch();
    error UnexpectedMakingAmount();
    error OnlyAggregationRouter();
    error NativeETHNotSupported();
    error Unauthorized();
    error WithdrawalDelayMisconfigured();

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
     * @dev Tokens never leave the Safe. The Safe approves the router, the router executes the
     *      swap, the module verifies the output, and the approval is revoked.
     *
     *      Reverts if the Safe has a pending Fusion swap — the trailing `approve(router, 0)`
     *      in `_classicSwapERC20` would otherwise clobber the live Fusion allowance and brick
     *      the Fusion fill.
     *
     *      Arms `swapInProgress[safe]` for the duration of the router call so that liquidation
     *      cannot fire mid-swap when the Safe is temporarily mid-transfer (matters when `data`
     *      is a LOP fillOrder calldata whose maker-side hooks could trigger liquidate()).
     *
     *      Performs an explicit `ensureHealth` at the end — `EtherFiHook.postOpHook` skips its
     *      automatic LTV check for this module, so we enforce it here instead.
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
        if (pendingSwaps[safe].fromAmount != 0) revert SwapAlreadyPending();

        _verifyClassicSwap(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data, signers, signatures);

        swapInProgress[safe] = true;
        _classicSwap(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data);
        swapInProgress[safe] = false;

        _ensureHealth(safe);
    }

    /// @dev Extracted to break stack pressure in `swap()`.
    function _verifyClassicSwap(address safe, address fromAsset, address toAsset, uint256 fromAssetAmount, uint256 minToAssetAmount, bytes calldata data, address[] calldata signers, bytes[] calldata signatures) internal {
        uint256 nonce_ = IEtherFiSafe(safe).useNonce();
        bytes32 dataHash = keccak256(data);
        bytes32 structHash = keccak256(abi.encode(SWAP_TYPEHASH, safe, address(this), fromAsset, toAsset, fromAssetAmount, minToAssetAmount, dataHash, nonce_));
        _verifyStructHash(safe, structHash, signers, signatures);
    }

    // ══════════════════════════════════════════════
    //  FUSION (RFQ / INTENT) SWAP — Safe-as-Maker
    // ══════════════════════════════════════════════

    /**
     * @notice Opens a Fusion swap: constructs the LOP order, records intent, registers pending withdrawal, approves router
     * @dev Atomically:
     *      1. builds a fixed extension that pins PRE + POST interaction callbacks to this module
     *      2. builds MakerTraits with HAS_EXTENSION | PRE_INTERACTION | POST_INTERACTION | NO_PARTIAL_FILLS
     *         and the user-supplied expiration
     *      3. constructs the LOP `Order` struct (maker = safe, receiver = 0, makingAmount = fromAmount,
     *         takingAmount = minToAmount, salt derived from useNonce + extension hash)
     *      4. computes the orderHash by calling `aggregationRouter.hashOrder(order)`
     *      5. verifies Safe-owner quorum over the intent + expiration
     *      6. registers a pending withdrawal on CashModule (preemptable by card spend) and approves the router
     *
     *      Because the entire order is built on-chain, requestSwap cannot register a hash that
     *      corresponds to an order missing pre/post-interaction callbacks. Combined with
     *      `EtherFiSafe.isValidSignature` binding to `pendingSwaps[safe].orderHash`, only this
     *      exact reconstructed order can be filled.
     *
     *      With NO_PARTIAL_FILLS_FLAG, the LOP requires the taker to pay exactly `minToAmount`
     *      for exactly `fromAmount` of maker tokens. The `minToAmount` therefore doubles as the
     *      fixed taking amount — owners are signing off on this specific price.
     * @param safe Address of the EtherFi Safe
     * @param fromToken Token the Safe is selling
     * @param toToken Token the Safe wants to receive
     * @param fromAmount Maker amount (exact)
     * @param minToAmount Taker amount; with NO_PARTIAL_FILLS this is the exact price the order will fill at
     * @param expiration Unix-timestamp (uint40) after which the order is rejected by LOP. 0 means no expiry.
     * @param signers Safe owner addresses authorizing this swap
     * @param signatures Signatures from the signers
     */
    function requestSwap(address safe, address fromToken, address toToken, uint256 fromAmount, uint256 minToAmount, uint40 expiration, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        if (pendingSwaps[safe].fromAmount != 0) revert SwapAlreadyPending();
        if (fromToken == ETH || toToken == ETH) revert NativeETHNotSupported();
        if (fromToken == toToken) revert SwappingToSameAsset();
        if (fromAmount == 0 || minToAmount == 0) revert InvalidInput();

        // Fail closed if the cash-module's withdrawal delay is zero. The cash-module also
        // substitutes a non-zero effective delay for this module's withdrawals; this check is
        // belt-and-suspenders in case the cash-module-side guard ever regresses.
        _requireNonZeroWithdrawalDelay();

        bytes32 orderHash = _verifyAndComputeOrderHash(safe, fromToken, toToken, fromAmount, minToAmount, expiration, signers, signatures);

        // `_checkAmountAvailable` is intentionally skipped here. `requestWithdrawalByModule`
        // cancels and replaces any existing pending withdrawal before committing, and its
        // internal `_checkBalance` is the authoritative balance check.
        cashModule.requestWithdrawalByModule(safe, fromToken, fromAmount);

        PendingSwap storage p = pendingSwaps[safe];
        p.fromToken = fromToken;
        p.toToken = toToken;
        p.fromAmount = fromAmount;
        p.minToAmount = minToAmount;
        p.orderHash = orderHash;

        // Arm the liquidation lock for the full intent lifetime — set here, cleared on
        // fill / cancel / preempt. A third party cannot liquidate a Safe with an open Fusion
        // intent. CashModule-driven preemption (card spend) still clears the flag via
        // `cancelBridgeByCashModule`.
        swapInProgress[safe] = true;

        _approveRouter(safe, fromToken, fromAmount);

        emit FusionSwapRequested(safe, fromToken, toToken, fromAmount, minToAmount, orderHash);
    }

    /// @dev Consumes the safe nonce, verifies the owner-quorum signature over the request struct,
    ///      and returns the LOP orderHash for the reconstructed order. Extracted to flatten the
    ///      stack in `requestSwap()`.
    function _verifyAndComputeOrderHash(address safe, address fromToken, address toToken, uint256 fromAmount, uint256 minToAmount, uint40 expiration, address[] calldata signers, bytes[] calldata signatures) internal returns (bytes32) {
        uint256 nonce_ = IEtherFiSafe(safe).useNonce();
        bytes32 structHash = keccak256(abi.encode(REQUEST_SWAP_TYPEHASH, safe, address(this), fromToken, toToken, fromAmount, minToAmount, expiration, nonce_));
        _verifyStructHash(safe, structHash, signers, signatures);
        return _registerOrder(safe, fromToken, toToken, fromAmount, minToAmount, expiration, nonce_);
    }

    /// @dev Builds the LOP order in-memory from the validated intent, asks the aggregator for its hash.
    ///      Extracted to break stack pressure in `requestSwap()`.
    function _registerOrder(address safe, address fromToken, address toToken, uint256 fromAmount, uint256 minToAmount, uint40 expiration, uint256 nonce_) internal view returns (bytes32 orderHash) {
        bytes memory extension = _buildExtension();
        uint256 extLower160 = uint256(keccak256(extension)) & type(uint160).max;

        // Upper 96 bits of salt = safe nonce → guarantees orderHash uniqueness per requestSwap call.
        // Lower 160 bits = keccak256(extension) lower 160 → satisfies LOP's `isValidExtension` rule.
        uint256 salt = (nonce_ << 160) | extLower160;

        // Pack the safe nonce (lower 40 bits) into MakerTraits.nonceOrEpoch so each order targets
        // a distinct cell in LOP's per-maker bit invalidator. With NO_PARTIAL_FILLS, LOP's
        // `useBitInvalidator()` is true; if every order shared `nonceOrEpoch = 0` they would all
        // land on the same cell and only the first fill from a given Safe would succeed.
        uint256 makerTraitsBits = _NO_PARTIAL_FILLS_FLAG | _PRE_INTERACTION_CALL_FLAG | _POST_INTERACTION_CALL_FLAG | _HAS_EXTENSION_FLAG | (uint256(expiration) << _EXPIRATION_OFFSET) | ((nonce_ & type(uint40).max) << _NONCE_OR_EPOCH_OFFSET);

        IOrderMixin.Order memory order = IOrderMixin.Order({ salt: salt, maker: Address.wrap(uint256(uint160(safe))), receiver: Address.wrap(0), makerAsset: Address.wrap(uint256(uint160(fromToken))), takerAsset: Address.wrap(uint256(uint160(toToken))), makingAmount: fromAmount, takingAmount: minToAmount, makerTraits: MakerTraits.wrap(makerTraitsBits) });

        orderHash = IOrderMixin(aggregationRouter).hashOrder(order);
    }

    /// @dev Reverts if the cash-module's withdrawal delay is 0. Extracted from `requestSwap`
    ///      to keep that function under the stack-depth limit.
    function _requireNonZeroWithdrawalDelay() internal view {
        (uint64 wd,,) = cashModule.getDelays();
        if (wd == 0) revert WithdrawalDelayMisconfigured();
    }

    /// @dev Has the Safe approve the 1inch router for the maker amount. Pre-clears any stale
    ///      router allowance to handle USDT-style "set-nonzero-from-nonzero-reverts" tokens
    ///      (M-3) — atomic with the new approval, so the final state is exactly `fromAmount`.
    function _approveRouter(address safe, address fromToken, uint256 fromAmount) internal {
        address[] memory to = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);
        to[0] = fromToken;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, aggregationRouter, 0);
        to[1] = fromToken;
        data[1] = abi.encodeWithSelector(IERC20.approve.selector, aggregationRouter, fromAmount);
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    /// @dev Builds the order extension that pins PRE_INTERACTION and POST_INTERACTION targets to
    ///      `address(this)`. Layout per `ExtensionLib`:
    ///      - bytes [0:32]   = offsets bitmap (uint32 cumulative-end per dynamic field)
    ///      - bytes [32:52]  = PreInteractionData  (20 bytes, address(this))
    ///      - bytes [52:72]  = PostInteractionData (20 bytes, address(this))
    ///      Fields 0..5 are empty (cumulative end = 0). Field 6 ends at 20, field 7 ends at 40.
    function _buildExtension() internal view returns (bytes memory) {
        uint256 offsets = (uint256(20) << 192) | (uint256(40) << 224);
        return abi.encodePacked(bytes32(offsets), bytes20(uint160(address(this))), bytes20(uint160(address(this))));
    }

    /**
     * @notice 1inch Limit Order Protocol pre-interaction hook — validates the in-flight order
     * @dev Invoked by the 1inch Aggregation Router from inside `_fill` BEFORE any token transfers.
     *      Validates the same intent fields as postInteraction so a malicious order whose
     *      extension points pre-interaction here but lies about the order shape cannot proceed.
     *
     *      `swapInProgress[safe]` is armed in `requestSwap` and covers the entire intent
     *      lifetime; this hook re-asserts it (idempotent).
     *
     *      No `nonReentrant`: cross-safe swaps (one Safe filling another Safe's Fusion order)
     *      enter the module twice in the same call frame — once for the taker via `swap()`
     *      and once via the maker pre/postInteraction. A reentrancy guard would brick that.
     *      The router-only authorization and state validation keep this safe.
     */
    function preInteraction(
        IOrderMixin.Order calldata order,
        bytes calldata,
        /* extension */
        bytes32 orderHash,
        address,
        /* taker */
        uint256 makingAmount,
        uint256 takingAmount,
        uint256,
        /* remainingMakingAmount */
        bytes calldata /* extraData */
    )
        external
    {
        if (msg.sender != aggregationRouter) revert OnlyAggregationRouter();

        address safe = order.maker.get();
        PendingSwap memory pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();
        if (orderHash != pendingSwap.orderHash) revert OrderHashMismatch();
        if (order.makerAsset.get() != pendingSwap.fromToken || order.takerAsset.get() != pendingSwap.toToken) revert OrderTokenMismatch();
        if (makingAmount != pendingSwap.fromAmount) revert UnexpectedMakingAmount();
        if (takingAmount < pendingSwap.minToAmount) revert InsufficientReceivedAmount();

        // Already true after requestSwap; re-asserting is idempotent and survives any future
        // refactor that removes the requestSwap-side write. Cleared in postInteraction /
        // cancelSwap / cancelBridgeByCashModule.
        swapInProgress[safe] = true;
    }

    /**
     * @notice 1inch Limit Order Protocol post-interaction hook — finalizes the Fusion swap atomically with the fill
     * @dev Invoked by the 1inch Aggregation Router from inside `_fill`, after both `transferFrom`s have settled.
     *      For the protocol to route the call here (instead of to the Safe / maker), the order's extension
     *      must encode this module's address as the first 20 bytes of the PostInteractionData field, and
     *      `MakerTraits` must have the POST_INTERACTION_CALL_FLAG (bit 251) and HAS_EXTENSION_FLAG (bit 249)
     *      set. `requestSwap()` enforces this at registration time.
     *
     *      No `nonReentrant`: see preInteraction. Cross-safe swaps require this. The same call
     *      frame re-enters us via `cashModule.cancelWithdrawalByModule -> cancelBridgeByCashModule`;
     *      we tolerate that by clearing local state before the callback.
     *
     *      Performs an explicit `ensureHealth` at the end — `EtherFiHook.postOpHook` skips its
     *      automatic LTV check for this module, so we enforce it here instead.
     */
    function postInteraction(
        IOrderMixin.Order calldata order,
        bytes calldata,
        /* extension */
        bytes32 orderHash,
        address,
        /* taker */
        uint256 makingAmount,
        uint256 takingAmount,
        uint256,
        /* remainingMakingAmount */
        bytes calldata /* extraData */
    )
        external
    {
        if (msg.sender != aggregationRouter) revert OnlyAggregationRouter();

        address safe = order.maker.get();
        PendingSwap memory pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();
        if (orderHash != pendingSwap.orderHash) revert OrderHashMismatch();
        if (order.makerAsset.get() != pendingSwap.fromToken || order.takerAsset.get() != pendingSwap.toToken) revert OrderTokenMismatch();
        if (makingAmount != pendingSwap.fromAmount) revert UnexpectedMakingAmount();
        if (takingAmount < pendingSwap.minToAmount) revert InsufficientReceivedAmount();

        _revokeApproval(safe, pendingSwap.fromToken);

        // Delete local state BEFORE releasing the CashModule withdrawal. cancelWithdrawalByModule
        // triggers _cancelOldWithdrawal → IBridgeModule(this).cancelBridgeByCashModule(safe) as a
        // callback; with fromAmount already zero, the callback short-circuits (no duplicate event,
        // no redundant approval revoke).
        delete pendingSwaps[safe];
        swapInProgress[safe] = false;
        cashModule.cancelWithdrawalByModule(safe);

        _ensureHealth(safe);

        emit FusionSwapSettled(safe, pendingSwap.fromToken, pendingSwap.toToken, pendingSwap.fromAmount, takingAmount);
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

        bytes32 structHash = keccak256(abi.encode(CANCEL_SWAP_TYPEHASH, safe, address(this), IEtherFiSafe(safe).useNonce()));
        _verifyStructHash(safe, structHash, signers, signatures);

        _revokeApproval(safe, pendingSwap.fromToken);

        // Delete before releasing the CashModule withdrawal (callback short-circuits — see postInteraction)
        delete pendingSwaps[safe];
        swapInProgress[safe] = false;
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
     *
     *      The approval revoke uses `execTransactionFromModule` which would normally trigger
     *      `EtherFiHook.postOpHook -> ensureHealth` and DOS liquidations / spend on an unhealthy
     *      Safe. The hook skips `ensureHealth` for this module specifically because this path
     *      is reachable from liquidation and card-spend flows where the Safe is expected to be
     *      unhealthy.
     * @param safe Address of the EtherFi Safe
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != etherFiDataProvider.getCashModule()) revert Unauthorized();

        PendingSwap memory pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) return;

        delete pendingSwaps[safe];
        swapInProgress[safe] = false;
        _revokeApproval(safe, pendingSwap.fromToken);

        emit FusionSwapCancelled(safe, pendingSwap.fromToken, pendingSwap.orderHash);
    }

    // ──────────────────────────────────────────────
    //  Admin recovery
    // ──────────────────────────────────────────────

    /**
     * @notice Admin-only recovery for maker tokens stuck at this module
     * @dev If both the cash-module-side and module-side `withdrawalDelay==0` guards are ever
     *      bypassed (e.g. by a pre-fix on-chain state, or a future regression), this function
     *      clears the orphaned `pendingSwaps[safe]` entry AND transfers the Safe's registered
     *      maker amount back to the Safe.
     *
     *      Operates only on the per-Safe pending entry — does not let admins sweep arbitrary
     *      stray tokens. If the module address holds excess balance beyond what's in
     *      `pendingSwaps`, this function does not touch it (use a separate recovery flow).
     *
     *      Gated on DATA_PROVIDER_ADMIN_ROLE for symmetry with `setOneInchSwapModule`.
     *
     *      No reentrancy concern: token transfer goes to the Safe (a controlled contract),
     *      and all module state is cleared before the external call.
     * @param safe Address of the EtherFi Safe whose pending entry should be recovered
     */
    function recoverStuckMakerTokens(address safe) external {
        if (!etherFiDataProvider.roleRegistry().hasRole(DATA_PROVIDER_ADMIN_ROLE, msg.sender)) revert Unauthorized();

        PendingSwap memory pendingSwap = pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();

        delete pendingSwaps[safe];
        swapInProgress[safe] = false;

        uint256 bal = IERC20(pendingSwap.fromToken).balanceOf(address(this));
        uint256 amount = bal < pendingSwap.fromAmount ? bal : pendingSwap.fromAmount;
        if (amount > 0) IERC20(pendingSwap.fromToken).transfer(safe, amount);

        emit FusionSwapRecovered(safe, pendingSwap.fromToken, amount, pendingSwap.orderHash);
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

    /// @dev Reverts if the Safe is unhealthy at LTV. Used at the tail of swap()/postInteraction
    ///      because EtherFiHook.postOpHook intentionally skips its automatic check for this module.
    function _ensureHealth(address safe) internal view {
        IDebtManager(cashModule.getDebtManager()).ensureHealth(safe);
    }

    // ══════════════════════════════════════════════
    //  INTERNAL: EIP-712 Signature Verification
    // ══════════════════════════════════════════════

    /**
     * @dev Verifies an EIP-712 structured signature under the Safe's domain. Caller computes
     *      `structHash` from the appropriate TYPEHASH + fields + fresh nonce. Each TYPEHASH
     *      includes `address module` (`address(this)`) so signatures cannot be replayed across
     *      modules that share the Safe's domain separator.
     */
    function _verifyStructHash(address safe, bytes32 structHash, address[] calldata signers, bytes[] calldata signatures) internal view {
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", IEtherFiSafe(safe).getDomainSeparator(), structHash));
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }
}
