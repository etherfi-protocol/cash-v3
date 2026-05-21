// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IOrderMixin } from "@1inch/limit-order-protocol-contract/contracts/interfaces/IOrderMixin.sol";
import { IPreInteraction } from "@1inch/limit-order-protocol-contract/contracts/interfaces/IPreInteraction.sol";
import { MakerTraits } from "@1inch/limit-order-protocol-contract/contracts/libraries/MakerTraitsLib.sol";
import { Address, AddressLib } from "@1inch/solidity-utils/contracts/libraries/AddressLib.sol";

import { IBridgeModule } from "../../interfaces/IBridgeModule.sol";
import { IDebtManager } from "../../interfaces/IDebtManager.sol";
import { IEtherFiSafe } from "../../interfaces/IEtherFiSafe.sol";
import { ISwapInteractionInterface } from "../../interfaces/ISwapInteractionInterface.sol";
import { UpgradeableProxy } from "../../utils/UpgradeableProxy.sol";
import { ModuleBase } from "../ModuleBase.sol";
import { ModuleCheckBalance } from "../ModuleCheckBalance.sol";

/**
 * @title OneInchSwapModule
 * @author ether.fi
 * @notice Module for executing token swaps through 1inch — Classic (DEX) and Fusion (RFQ).
 *
 * @dev Classic: atomic single-tx swap via `swap()`. Safe approves router, router swaps via DEXes,
 *      module verifies output, approval is revoked. Tokens never leave the Safe.
 *
 *      Fusion: async intent-based swap via `requestSwap()` → fill → `{preInteraction(),
 *      postInteraction()}`, or `cancelSwap()` to abort. The Safe is the maker in a LOP order
 *      built by the backend (plain-LOP or Settlement-routed). `requestSwap()` verifies the order
 *      against the user-signed intent, checks MakerTraits + extension hook routing, and binds the
 *      router-computed orderHash into the EIP-712 signature. At fill time `preInteraction`
 *      snapshots the Safe's fromToken/toToken balances; `postInteraction` enforces the deltas
 *      against `fromAmount` / `minToAmount`. `EtherFiSafe.isValidSignature` authorizes the fill by
 *      comparing the LOP-computed orderHash against `pendingSwaps[safe].orderHash`.
 */
contract OneInchSwapModule is UpgradeableProxy, ModuleBase, ModuleCheckBalance, IBridgeModule, ISwapInteractionInterface, IPreInteraction {
    using AddressLib for Address;

    // ──────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────

    /// @notice State of a pending Fusion swap for a Safe. `minToAmount` is the net amount the
    ///         Safe must receive (post-fee, if any) — enforced at `postInteraction` via the
    ///         balance-delta check.
    struct PendingSwap {
        address fromToken;
        address toToken;
        uint256 fromAmount;
        uint256 minToAmount;
        bytes32 orderHash;
    }

    /// @notice Intent fields the Safe owners sign over. The full LOP order is constructed by the
    ///         backend; on-chain we verify the supplied order matches this intent and that its
    ///         safety hooks (pre + post interaction) route through this module.
    struct SwapIntent {
        address safe;
        address fromToken;
        address toToken;
        uint256 fromAmount;
        uint256 minToAmount;
        uint40 expiration;
    }

    /// @notice Decoded view of the LOP `extension` bytes the backend must produce. Mirrors the
    ///         field layout defined by LOP's `OrderLib` / `ExtensionLib` — see
    ///         `docs/1inch/extension-structure.md` for the byte-level spec.
    ///
    ///         The full LOP extension has 8 fields (0..7). For this module only fields 2, 3, 6, 7
    ///         carry payload; fields 0, 1, 4, 5 must be empty. Adding a new field is a two-place
    ///         change: extend `ExpectedExtension` *and* update the doc.
    struct ExpectedExtension {
        bytes makingAmountData;     // field 2: Fusion auction data (Settlement-aware) or empty for plain-LOP
        bytes takingAmountData;     // field 3: Fusion auction data (Settlement-aware) or empty for plain-LOP
        bytes preInteractionData;   // field 6: exactly 20 bytes — must equal address(this)
        bytes postInteractionData;  // field 7: trailing 20 bytes — must equal address(this)
    }

    // ──────────────────────────────────────────────
    //  Immutables (set in the implementation constructor; baked into bytecode)
    // ──────────────────────────────────────────────

    /// @notice 1inch Aggregation Router address (shared by Classic and Fusion).
    address public immutable aggregationRouter;

    /// @notice 1inch Fusion `SimpleSettlement` extension address.
    address public immutable settlementContract;

    /// @notice Operating safe — destination for `rescueFunds`. Tokens stranded at this module
    ///         (e.g. mis-sent transfers) are recoverable only here.
    address public immutable operatingSafe;

    // ──────────────────────────────────────────────
    //  Roles
    // ──────────────────────────────────────────────

    /// @notice Required to call `rescueFunds`. Shares the same hash as
    ///         `EtherFiDataProvider.DATA_PROVIDER_ADMIN_ROLE`.
    bytes32 public constant DATA_PROVIDER_ADMIN_ROLE = keccak256("DATA_PROVIDER_ADMIN_ROLE");

    /// @notice Backend-keeper role authorized to cancel a Safe's pending Fusion swap without an
    ///         owner-quorum signature (e.g. for expired orders, stuck intents, ops cleanup).
    bytes32 public constant ONEINCH_SWAP_CANCEL_ROLE = keccak256("ONEINCH_SWAP_CANCEL_ROLE");

    /// @notice Backend-EOA role authorized to submit `requestSwap` on a Safe's behalf. The
    ///         owner-quorum signature over REQUEST_SWAP_TYPEHASH is still required — this role
    ///         only restricts which EOA may relay the on-chain call.
    bytes32 public constant ONEINCH_SWAP_REQUEST_ROLE = keccak256("ONEINCH_SWAP_REQUEST_ROLE");

    // ──────────────────────────────────────────────
    //  ERC-7201 namespaced storage
    // ──────────────────────────────────────────────

    /// @custom:storage-location erc7201:etherfi.storage.OneInchSwapModule
    struct OneInchSwapModuleStorage {
        /// @notice Pending Fusion swap per Safe (only one at a time)
        mapping(address safe => PendingSwap) pendingSwaps;
        /// @notice True for the duration of an in-flight router fill (set in preInteraction,
        ///         cleared in postInteraction) or a classic `swap()` call. `DebtManager.liquidate`
        ///         reverts when set, blocking same-tx liquidation during a fill.
        mapping(address safe => bool) swapInProgress;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.OneInchSwapModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OneInchSwapModuleStorageLocation = 0xf4914529dfb4f942d30987dd4030d70d0d5360342620a3ce557acbdc08173500;

    function _getStorage() private pure returns (OneInchSwapModuleStorage storage $) {
        assembly {
            $.slot := OneInchSwapModuleStorageLocation
        }
    }

    // ──────────────────────────────────────────────
    //  Transient storage slots (per-safe balance snapshots, pre → post)
    // ──────────────────────────────────────────────

    /// @dev Transient-storage namespace constants. Per-safe slots derived via
    ///      `keccak256(abi.encode(safe, _FROM_BAL_TSLOT))`. Scoped to a single tx — cleared
    ///      automatically by the EVM at the end of the call.
    bytes32 private constant _FROM_BAL_TSLOT = keccak256("etherfi.oneinch.transient.fromBal");
    bytes32 private constant _TO_BAL_TSLOT = keccak256("etherfi.oneinch.transient.toBal");

    // ──────────────────────────────────────────────
    //  EIP-712 type hashes (unified with EtherFiSafe's signing scheme)
    // ──────────────────────────────────────────────

    /// @notice Classic (DEX aggregation) swap typehash. `module` binds the signature to this
    ///         contract so it cannot be replayed across modules sharing the Safe's domain.
    bytes32 public constant SWAP_TYPEHASH = keccak256("ClassicSwap(address safe,address module,address fromAsset,address toAsset,uint256 fromAssetAmount,uint256 minToAssetAmount,bytes data,uint256 nonce)");

    /// @notice Fusion request typehash. Owners sign over the swap intent + the LOP orderHash —
    ///         binding `orderHash` commits the user to the exact order shape (auction params,
    ///         resolver whitelist, fee structure, salt, MakerTraits). `module` binds the
    ///         signature to this contract.
    bytes32 public constant REQUEST_SWAP_TYPEHASH = keccak256("RequestSwap(address safe,address module,address fromToken,address toToken,uint256 fromAmount,uint256 minToAmount,uint40 expiration,bytes32 orderHash,uint256 nonce)");

    /// @notice Fusion cancel typehash for the owner-quorum cancel path. `module` binds the
    ///         signature to this contract.
    bytes32 public constant CANCEL_SWAP_TYPEHASH = keccak256("CancelSwap(address safe,address module,uint256 nonce)");

    // ──────────────────────────────────────────────
    //  LOP MakerTraits layout constants
    // ──────────────────────────────────────────────

    /// @dev MakerTraits flag bit positions (from MakerTraitsLib).
    uint256 private constant _NO_PARTIAL_FILLS_FLAG = 1 << 255;
    uint256 private constant _PRE_INTERACTION_CALL_FLAG = 1 << 252;
    uint256 private constant _POST_INTERACTION_CALL_FLAG = 1 << 251;
    uint256 private constant _HAS_EXTENSION_FLAG = 1 << 249;

    /// @dev Bit offset of the uint40 expiration field within MakerTraits.
    uint256 private constant _EXPIRATION_OFFSET = 80;

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    /// @notice Emitted on a successful classic (DEX) swap
    event ClassicSwap(address indexed safe, address indexed fromAsset, address indexed toAsset, uint256 fromAssetAmount, uint256 minToAssetAmount, uint256 returnAmount);

    /// @notice Emitted when a Fusion swap is requested (intent recorded, router approved)
    event FusionSwapRequested(address indexed safe, address indexed fromToken, address indexed toToken, uint256 fromAmount, uint256 minToAmount, bytes32 orderHash);

    /// @notice Emitted when a Fusion swap is settled after fill
    event FusionSwapSettled(address indexed safe, address indexed fromToken, address indexed toToken, uint256 fromAmount, uint256 receivedAmount);

    /// @notice Emitted when a Fusion swap is cancelled (owner sig, role-EOA, or card-spend preemption)
    event FusionSwapCancelled(address indexed safe, address indexed fromToken, bytes32 indexed orderHash);

    /// @notice Emitted when admin sweeps stranded tokens out of this module to the operating safe
    event FundsRescued(address indexed token, uint256 amount);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error SwappingToSameAsset();
    error InvalidSignatures();
    error OutputLessThanMinAmount();
    error NoPendingSwap();
    error SwapAlreadyPending();
    error InsufficientReceivedAmount();
    error UnexpectedFromTokenDelta();
    error OrderHashMismatch();
    error OrderTokenMismatch();
    error OrderMakerMismatch();
    error UnexpectedMakingAmount();
    error UnexpectedTakingAmount();
    error OnlyAggregationRouter();
    error OnlyAggregationRouterOrSettlement();
    error NativeETHNotSupported();
    error WithdrawalDelayMisconfigured();
    error MissingMakerTraitsFlag();
    error ExpirationMismatch();
    error InvalidExtension();
    error WrongPreInteractionTarget();
    error WrongPostInteractionTarget();
    error SaltExtensionMismatch();
    error MissingSnapshot();

    // ──────────────────────────────────────────────
    //  Constructor + initializer
    // ──────────────────────────────────────────────

    /**
     * @param _aggregationRouter 1inch Aggregation Router address (== LOP address)
     * @param _settlementContract 1inch `SimpleSettlement` extension address (Fusion settlement layer)
     * @param _dataProvider EtherFi data provider address
     * @param _operatingSafe Operating safe address — destination for `rescueFunds`
     */
    constructor(address _aggregationRouter, address _settlementContract, address _dataProvider, address _operatingSafe) ModuleBase(_dataProvider) ModuleCheckBalance(_dataProvider) {
        if (_aggregationRouter == address(0) || _aggregationRouter.code.length == 0) revert InvalidInput();
        if (_settlementContract == address(0) || _settlementContract.code.length == 0) revert InvalidInput();
        if (_operatingSafe == address(0)) revert InvalidInput();
        aggregationRouter = _aggregationRouter;
        settlementContract = _settlementContract;
        operatingSafe = _operatingSafe;
        _disableInitializers();
    }

    /**
     * @notice Initializes the proxy with the role registry
     * @param _roleRegistry Address of the RoleRegistry that gates upgrades and pause
     */
    function initialize(address _roleRegistry) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
    }

    // ══════════════════════════════════════════════
    //  Public views
    // ══════════════════════════════════════════════

    /// @notice Returns the pending Fusion swap details for a Safe
    function getPendingSwap(address safe) external view returns (PendingSwap memory) {
        return _getStorage().pendingSwaps[safe];
    }

    /// @notice True for the duration of an in-flight router fill (preInteraction → postInteraction)
    ///         or a classic `swap()` call. Read by `DebtManager.liquidate` to block liquidation
    ///         while a Safe's tokens are mid-transfer.
    function swapInProgress(address safe) external view returns (bool) {
        return _getStorage().swapInProgress[safe];
    }

    // ══════════════════════════════════════════════
    //  CLASSIC (DEX) SWAP
    // ══════════════════════════════════════════════

    /**
     * @notice Executes an atomic token swap through 1inch DEX aggregation
     * @dev Tokens never leave the Safe. The Safe approves the router, the router swaps, the
     *      module verifies the output, the approval is revoked.
     *
     *      Reverts if a Fusion swap is pending on the Safe — the trailing `approve(router, 0)`
     *      would otherwise wipe the live Fusion allowance.
     *
     *      Arms `swapInProgress[safe]` around the router call so liquidation cannot fire while
     *      a LOP fillOrder calldata moves tokens through the Safe's maker-side hooks.
     *
     *      `_ensureHealth` at the tail because `EtherFiHook.postOpHook` skips its automatic LTV
     *      check for this module.
     */
    function swap(address safe, address fromAsset, address toAsset, uint256 fromAssetAmount, uint256 minToAssetAmount, bytes calldata data, address[] calldata signers, bytes[] calldata signatures) external nonReentrant whenNotPaused onlyEtherFiSafe(safe) {
        OneInchSwapModuleStorage storage $ = _getStorage();
        if ($.pendingSwaps[safe].fromAmount != 0) revert SwapAlreadyPending();

        _verifyClassicSwap(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data, signers, signatures);

        $.swapInProgress[safe] = true;
        _classicSwap(safe, fromAsset, toAsset, fromAssetAmount, minToAssetAmount, data);
        $.swapInProgress[safe] = false;

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
     * @notice Opens a Fusion swap: validates the BE-constructed LOP order and records intent.
     * @dev Authorization is two-layered:
     *      - `msg.sender` must hold `ONEINCH_SWAP_REQUEST_ROLE`. The module is only ever called by
     *        the backend EOA; user multisigs do not call it directly.
     *      - the owner-quorum signature over REQUEST_SWAP_TYPEHASH is still verified — the role
     *        only restricts WHICH EOA may relay the call, not WHETHER the user authorized it.
     *
     *      On-chain invariants enforced against the supplied order:
     *      - intent fields match (maker, makerAsset, takerAsset, makingAmount, takingAmount)
     *      - MakerTraits carries HAS_EXTENSION | PRE_INTERACTION | POST_INTERACTION | NO_PARTIAL_FILLS
     *        and the user-intended expiration
     *      - salt's lower 160 bits commit to `keccak256(extension)` per LOP's `isValidExtension`
     *      - extension matches `ExpectedExtension` (fields 0/1/4/5 empty, field 6 == module,
     *        field 7 trailing 20B == module)
     *
     *      The router-computed orderHash is bound into the EIP-712 signature, so any BE-chosen
     *      fee / auction / whitelist byte is authorized by the owner-quorum.
     *      `EtherFiSafe.isValidSignature` later compares fill-time orderHash against
     *      `pendingSwaps[safe].orderHash` — only this exact order can fill.
     */
    function requestSwap(SwapIntent calldata intent, IOrderMixin.Order calldata order, bytes calldata extension, address[] calldata signers, bytes[] calldata signatures) external nonReentrant whenNotPaused onlyEtherFiSafe(intent.safe) {
        if (!roleRegistry().hasRole(ONEINCH_SWAP_REQUEST_ROLE, msg.sender)) revert Unauthorized();

        OneInchSwapModuleStorage storage $ = _getStorage();
        if ($.pendingSwaps[intent.safe].fromAmount != 0) revert SwapAlreadyPending();
        if (intent.fromToken == ETH || intent.toToken == ETH) revert NativeETHNotSupported();
        if (intent.fromToken == intent.toToken) revert SwappingToSameAsset();
        if (intent.fromAmount == 0 || intent.minToAmount == 0) revert InvalidInput();

        // Fail closed if the cash-module's withdrawal delay is zero — otherwise
        // `requestWithdrawalByModule` would synchronously transfer maker tokens out of the Safe.
        _requireNonZeroWithdrawalDelay();

        _validateOrderAgainstIntent(intent, order);
        _validateMakerTraits(intent.expiration, order.makerTraits);
        _validateExtension(order.salt, extension);

        bytes32 orderHash = IOrderMixin(aggregationRouter).hashOrder(order);
        _verifyRequestSignature(intent, orderHash, signers, signatures);

        _register(intent, orderHash);
    }

    /// @dev Storage writes + withdrawal registration + event emit. Extracted to keep
    ///      `requestSwap` under the stack-depth limit.
    function _register(SwapIntent calldata intent, bytes32 orderHash) internal {
        // `requestWithdrawalByModule` replaces any prior pending withdrawal on the Safe and runs
        // its own `_checkBalance`, so an explicit `_checkAmountAvailable` here would be redundant.
        cashModule.requestWithdrawalByModule(intent.safe, intent.fromToken, intent.fromAmount);

        PendingSwap storage p = _getStorage().pendingSwaps[intent.safe];
        p.fromToken = intent.fromToken;
        p.toToken = intent.toToken;
        p.fromAmount = intent.fromAmount;
        p.minToAmount = intent.minToAmount;
        p.orderHash = orderHash;

        emit FusionSwapRequested(intent.safe, intent.fromToken, intent.toToken, intent.fromAmount, intent.minToAmount, orderHash);
    }

    /// @dev Computes the REQUEST_SWAP_TYPEHASH struct hash, consumes a Safe nonce, and verifies
    ///      the owner-quorum signature.
    function _verifyRequestSignature(SwapIntent calldata intent, bytes32 orderHash, address[] calldata signers, bytes[] calldata signatures) internal {
        uint256 nonce_ = IEtherFiSafe(intent.safe).useNonce();
        bytes32 structHash = keccak256(abi.encode(REQUEST_SWAP_TYPEHASH, intent.safe, address(this), intent.fromToken, intent.toToken, intent.fromAmount, intent.minToAmount, intent.expiration, orderHash, nonce_));
        _verifyStructHash(intent.safe, structHash, signers, signatures);
    }

    /// @dev Verifies the order's intent-bearing fields match what the user signed.
    function _validateOrderAgainstIntent(SwapIntent calldata intent, IOrderMixin.Order calldata order) internal pure {
        if (order.maker.get() != intent.safe) revert OrderMakerMismatch();
        if (order.makerAsset.get() != intent.fromToken || order.takerAsset.get() != intent.toToken) revert OrderTokenMismatch();
        if (order.makingAmount != intent.fromAmount) revert UnexpectedMakingAmount();
        if (order.takingAmount != intent.minToAmount) revert UnexpectedTakingAmount();
    }

    /// @dev Verifies MakerTraits has the required flags and the user-intended expiration.
    function _validateMakerTraits(uint40 expiration, MakerTraits mt_) internal pure {
        uint256 bits = MakerTraits.unwrap(mt_);
        uint256 required = _NO_PARTIAL_FILLS_FLAG | _PRE_INTERACTION_CALL_FLAG | _POST_INTERACTION_CALL_FLAG | _HAS_EXTENSION_FLAG;
        if (bits & required != required) revert MissingMakerTraitsFlag();
        if (uint40(bits >> _EXPIRATION_OFFSET) != expiration) revert ExpirationMismatch();
    }

    /// @dev Decodes the LOP `extension` bytes into the `ExpectedExtension` view and enforces:
    ///      - salt commits to `keccak256(extension)` per LOP's `OrderLib.isValidExtension`
    ///      - fields 0, 1, 4, 5 are empty (unused by this module)
    ///      - field 6 is exactly 20 bytes and equals `address(this)` (preInteraction target)
    ///      - field 7's trailing 20 bytes equal `address(this)` (postInteraction target — used
    ///        both by plain-LOP, which calls us directly, and Settlement-routed Fusion, where
    ///        FeeTaker reads the trailing 20 bytes and chains into us)
    ///
    ///      LOP extension layout: `bytes[0:32]` is the offsets bitmap (uint32 cumulative-end per
    ///      field, field `i`'s end at bits `[i*32 : (i+1)*32]`); `bytes[32:]` is the concatenated
    ///      field bodies. Adding a new field is a two-place change: extend `ExpectedExtension`
    ///      and update `docs/1inch/extension-structure.md`.
    function _validateExtension(uint256 salt, bytes calldata extension) internal view {
        if (extension.length < 32) revert InvalidExtension();
        if (salt & type(uint160).max != uint256(keccak256(extension)) & type(uint160).max) revert SaltExtensionMismatch();

        uint256 offsets = uint256(bytes32(extension[:32]));
        uint256 end0 = offsets & type(uint32).max;
        uint256 end1 = (offsets >> 32) & type(uint32).max;
        uint256 end3 = (offsets >> 96) & type(uint32).max;
        uint256 end4 = (offsets >> 128) & type(uint32).max;
        uint256 end5 = (offsets >> 160) & type(uint32).max;
        uint256 end6 = (offsets >> 192) & type(uint32).max;
        uint256 end7 = (offsets >> 224) & type(uint32).max;

        // Fields 0, 1, 4, 5 must be empty (length = cumulative-end delta).
        if (end0 != 0) revert InvalidExtension();
        if (end1 - end0 != 0) revert InvalidExtension();
        if (end4 - end3 != 0) revert InvalidExtension();
        if (end5 - end4 != 0) revert InvalidExtension();

        // Field 6 = preInteractionData: exactly 20 bytes = address(this).
        if (end6 - end5 != 20) revert WrongPreInteractionTarget();
        // Field 7 = postInteractionData: at least 20 bytes, trailing 20 = address(this).
        if (end7 - end6 < 20) revert WrongPostInteractionTarget();
        if (extension.length < 32 + end7) revert InvalidExtension();

        address preTarget = address(bytes20(extension[32 + end5:32 + end5 + 20]));
        if (preTarget != address(this)) revert WrongPreInteractionTarget();

        address postTarget = address(bytes20(extension[32 + end7 - 20:32 + end7]));
        if (postTarget != address(this)) revert WrongPostInteractionTarget();
    }

    /// @dev Reverts if the cash-module's withdrawal delay is 0.
    function _requireNonZeroWithdrawalDelay() internal view {
        (uint64 wd,,) = cashModule.getDelays();
        if (wd == 0) revert WithdrawalDelayMisconfigured();
    }

    /// @dev Has the Safe approve the 1inch router for the maker amount. Pre-clears any stale
    ///      router allowance to handle USDT-style "set-nonzero-from-nonzero-reverts" tokens.
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

    /**
     * @notice LOP pre-interaction hook — validates the in-flight order, grants the router approval,
     *         and arms the fill window
     * @dev Called by the Aggregation Router inside `_fill`, before any maker-side transfers.
     *      Snapshots the Safe's fromToken + toToken balances into transient storage; the
     *      matching `postInteraction` reads them back and asserts `fromAmount` was spent and
     *      ≥ `minToAmount` was received.
     *
     *      Grants the router allowance for `fromAmount`, scoped to this fill tx — LOP's
     *      `_transferMakerAssetToTaker` consumes it between pre- and postInteraction.
     *
     *      Sets `swapInProgress` for the duration of the router fill so liquidation is blocked
     *      while the Safe's tokens are mid-transfer.
     *
     *      No `nonReentrant`: cross-safe swaps (one Safe filling another's Fusion order) re-enter
     *      the module in the same call frame; a reentrancy guard would brick them. Router-only
     *      authorization + pending-state validation keep this safe.
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
        OneInchSwapModuleStorage storage $ = _getStorage();
        PendingSwap memory pendingSwap = $.pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();
        if (orderHash != pendingSwap.orderHash) revert OrderHashMismatch();
        if (order.makerAsset.get() != pendingSwap.fromToken || order.takerAsset.get() != pendingSwap.toToken) revert OrderTokenMismatch();
        if (makingAmount != pendingSwap.fromAmount) revert UnexpectedMakingAmount();
        if (takingAmount < pendingSwap.minToAmount) revert InsufficientReceivedAmount();

        _snapshotSafeBalances(safe, pendingSwap.fromToken, pendingSwap.toToken);

        $.swapInProgress[safe] = true;

        _approveRouter(safe, pendingSwap.fromToken, pendingSwap.fromAmount);
    }

    /**
     * @notice LOP post-interaction hook — finalizes the Fusion swap atomically with the fill
     * @dev Authorized callers:
     *      - plain-LOP order: `msg.sender == aggregationRouter`, invoked directly from `_fill`.
     *      - Settlement-routed Fusion: `msg.sender == settlementContract`, invoked after
     *        Settlement skims its fee and chains here via FeeTaker's trailing-target pattern.
     *
     *      Enforces balance deltas against the snapshot taken in `preInteraction`:
     *      - Safe's fromToken balance must have decreased by exactly `fromAmount`
     *      - Safe's toToken balance must have increased by at least `minToAmount`
     *
     *      This is the ultimate guard against fee skim, MEV reroute, or token-side hooks that
     *      could otherwise let the Safe over-pay or under-receive.
     *
     *      No `nonReentrant`: cross-safe swaps re-enter in the same call frame, and
     *      `cashModule.cancelWithdrawalByModule -> cancelBridgeByCashModule` re-enters after
     *      we've already cleared state. A reentrancy guard would brick both.
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
        if (msg.sender != aggregationRouter && msg.sender != settlementContract) revert OnlyAggregationRouterOrSettlement();

        address safe = order.maker.get();
        OneInchSwapModuleStorage storage $ = _getStorage();
        PendingSwap memory pendingSwap = $.pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();
        if (orderHash != pendingSwap.orderHash) revert OrderHashMismatch();
        if (order.makerAsset.get() != pendingSwap.fromToken || order.takerAsset.get() != pendingSwap.toToken) revert OrderTokenMismatch();
        if (makingAmount != pendingSwap.fromAmount) revert UnexpectedMakingAmount();
        if (takingAmount < pendingSwap.minToAmount) revert InsufficientReceivedAmount();

        _validateBalanceDeltas(safe, pendingSwap.fromToken, pendingSwap.toToken, pendingSwap.fromAmount, pendingSwap.minToAmount);

        _revokeApproval(safe, pendingSwap.fromToken);

        // Clear local state before releasing the CashModule withdrawal — `cancelWithdrawalByModule`
        // callbacks into `cancelBridgeByCashModule`, which short-circuits when `fromAmount == 0`.
        delete $.pendingSwaps[safe];
        $.swapInProgress[safe] = false;
        cashModule.cancelWithdrawalByModule(safe);

        _ensureHealth(safe);

        emit FusionSwapSettled(safe, pendingSwap.fromToken, pendingSwap.toToken, pendingSwap.fromAmount, takingAmount);
    }

    /**
     * @notice Cancels a pending Fusion swap before settlement
     * @dev Two authorization paths (XOR):
     *      - owner-quorum signature path: `signers` non-empty; verified against CANCEL_SWAP_TYPEHASH
     *      - role-keeper path: `signers` empty; caller must hold `ONEINCH_SWAP_CANCEL_ROLE` on
     *        the RoleRegistry. Used by the backend to clear expired orders / stuck intents.
     *
     *      Releases the pending withdrawal on CashModule. Tokens remain on the Safe throughout.
     *      Router allowance is granted and consumed inside the fill tx, so none exists at cancel
     *      time.
     */
    function cancelSwap(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        OneInchSwapModuleStorage storage $ = _getStorage();
        PendingSwap memory pendingSwap = $.pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) revert NoPendingSwap();

        if (signers.length == 0) {
            if (!roleRegistry().hasRole(ONEINCH_SWAP_CANCEL_ROLE, msg.sender)) revert Unauthorized();
        } else {
            bytes32 structHash = keccak256(abi.encode(CANCEL_SWAP_TYPEHASH, safe, address(this), IEtherFiSafe(safe).useNonce()));
            _verifyStructHash(safe, structHash, signers, signatures);
        }

        delete $.pendingSwaps[safe];
        cashModule.cancelWithdrawalByModule(safe);

        emit FusionSwapCancelled(safe, pendingSwap.fromToken, pendingSwap.orderHash);
    }

    // ──────────────────────────────────────────────
    //  IBridgeModule (called by CashModule for force-cancellation)
    // ──────────────────────────────────────────────

    /**
     * @notice Called by CashModule to force-cancel a pending swap (card-spend preemption, liquidation)
     * @dev Clears state. Does NOT call `cancelWithdrawalByModule` — CashModule is already inside
     *      `_cancelOldWithdrawal` when this fires. Router allowance is granted and consumed inside
     *      the fill tx, so none exists when this fires.
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != etherFiDataProvider.getCashModule()) revert Unauthorized();

        OneInchSwapModuleStorage storage $ = _getStorage();
        PendingSwap memory pendingSwap = $.pendingSwaps[safe];
        if (pendingSwap.fromAmount == 0) return;

        delete $.pendingSwaps[safe];

        emit FusionSwapCancelled(safe, pendingSwap.fromToken, pendingSwap.orderHash);
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    /**
     * @notice Sweeps a token balance held by this module to the operating safe
     * @dev Bounded by `amount` — caller specifies how much. Used to recover tokens accidentally
     *      transferred to this module address (the module itself is not designed to hold funds;
     *      legitimate Fusion fills route tokens directly Safe ↔ router).
     *
     *      Gated on `DATA_PROVIDER_ADMIN_ROLE`.
     */
    function rescueFunds(address token, uint256 amount) external {
        if (amount == 0) revert InvalidInput();
        IERC20(token).transfer(operatingSafe, amount);
        emit FundsRescued(token, amount);
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

    /// @dev Revokes the router's fromToken approval on the Safe.
    function _revokeApproval(address safe, address fromToken) internal {
        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = fromToken;
        data[0] = abi.encodeWithSelector(IERC20.approve.selector, aggregationRouter, 0);
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    /// @dev Snapshots the Safe's fromToken + toToken balances into per-safe transient slots.
    function _snapshotSafeBalances(address safe, address fromToken, address toToken) internal {
        uint256 fromBal = IERC20(fromToken).balanceOf(safe);
        uint256 toBal = IERC20(toToken).balanceOf(safe);
        bytes32 fromSlot = keccak256(abi.encode(safe, _FROM_BAL_TSLOT));
        bytes32 toSlot = keccak256(abi.encode(safe, _TO_BAL_TSLOT));
        // Tag the high bit so `0` is distinguishable from "never snapshotted" (in case the
        // pre-hook is skipped). Stored value is `bal | (1 << 255)`; reader strips it.
        assembly ("memory-safe") {
            let tag := shl(255, 1)
            tstore(fromSlot, or(fromBal, tag))
            tstore(toSlot, or(toBal, tag))
        }
    }

    /// @dev Asserts post-fill deltas against the snapshot taken in `preInteraction`. Clears the
    ///      transient slots so a malicious post-only invocation can't replay against a stale
    ///      snapshot in the same tx.
    function _validateBalanceDeltas(address safe, address fromToken, address toToken, uint256 fromAmount, uint256 minToAmount) internal {
        bytes32 fromSlot = keccak256(abi.encode(safe, _FROM_BAL_TSLOT));
        bytes32 toSlot = keccak256(abi.encode(safe, _TO_BAL_TSLOT));
        uint256 raw1;
        uint256 raw2;
        assembly ("memory-safe") {
            raw1 := tload(fromSlot)
            raw2 := tload(toSlot)
            tstore(fromSlot, 0)
            tstore(toSlot, 0)
        }
        uint256 tag = 1 << 255;
        if (raw1 == 0 || raw2 == 0) revert MissingSnapshot();
        uint256 fromBalBefore = raw1 & ~tag;
        uint256 toBalBefore = raw2 & ~tag;

        uint256 fromBalAfter = IERC20(fromToken).balanceOf(safe);
        uint256 toBalAfter = IERC20(toToken).balanceOf(safe);

        // Maker side: Safe must have spent exactly `fromAmount`. Catches fee-on-transfer tokens
        // and any token-side hook that pulled more (or less) than the order specified.
        if (fromBalBefore - fromBalAfter != fromAmount) revert UnexpectedFromTokenDelta();

        // Taker side: Safe must have received ≥ `minToAmount` net (after any Settlement fee).
        if (toBalAfter - toBalBefore < minToAmount) revert InsufficientReceivedAmount();
    }

    /// @dev Reverts if the Safe is unhealthy at LTV.
    function _ensureHealth(address safe) internal view {
        IDebtManager(cashModule.getDebtManager()).ensureHealth(safe);
    }

    // ══════════════════════════════════════════════
    //  INTERNAL: EIP-712 Signature Verification
    // ══════════════════════════════════════════════

    /**
     * @dev Verifies an EIP-712 structured signature under the Safe's domain. Each TYPEHASH
     *      includes `address module` (`address(this)`) so signatures cannot be replayed across
     *      modules sharing the Safe's domain separator.
     */
    function _verifyStructHash(address safe, bytes32 structHash, address[] calldata signers, bytes[] calldata signatures) internal view {
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", IEtherFiSafe(safe).getDomainSeparator(), structHash));
        if (!IEtherFiSafe(safe).checkSignatures(digestHash, signers, signatures)) revert InvalidSignatures();
    }
}
