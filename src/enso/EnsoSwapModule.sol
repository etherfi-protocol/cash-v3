// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IBridgeModule } from "../interfaces/IBridgeModule.sol";
import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";
import { ModuleCheckBalance } from "../modules/ModuleCheckBalance.sol";
import { ModuleLendGatewaySandwich } from "../modules/ModuleLendGatewaySandwich.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title EnsoSwapModule
 * @author ether.fi
 * @notice Swap module that routes same-chain and cross-chain swaps through Enso. The user
 *         signs ONE intent at `requestSwap`, which also stores the BE-supplied Enso
 *         `router`-strategy calldata. After the CashModule withdrawal delay matures the
 *         keeper calls `executeSwap(safe)` — taking only the safe address — which replays
 *         the stored swap verbatim: it releases the solvency hold and drives the safe to
 *         approve the pinned Enso Router and forward the calldata.
 *         Native-fee routes use `requestSwapWithNativeFee`; the exact signed fee is supplied
 *         by the keeper at execution and forwarded through the safe to the Enso Router.
 * @dev The Enso calldata (`swapData`) is built off-chain by the BE via the Enso Route/Bundle
 *      API with the `router` routing strategy and stored at request time, then forwarded
 *      verbatim — there is no on-chain min-out / balance enforcement. Slippage protection
 *      lives entirely inside the Enso calldata; `order.minOut` is carried only for the
 *      signed intent and events. Off-chain monitoring catches BE bugs or mis-routing.
 *
 *      The module always executes via `EtherFiSafe.execTransactionFromModule`, which is a
 *      plain `call` (never `delegatecall`), so ONLY Enso's `router` strategy is usable here
 *      (approve the router, then call it). The `delegate` strategy is not supported.
 *
 *      On the OP deploy the module hooks `CashModule.requestWithdrawalByModule` /
 *      `cancelWithdrawalByModule` to place a solvency hold for the duration of the
 *      CashModule withdrawal delay. Where the data provider's `cashModule` is the zero
 *      address (e.g. the mainnet `TradingSafe`) the hold mechanic is skipped and the swap
 *      executes immediately at request time.
 *
 *      The Enso Router address is admin-set (pinned) and every swap is forwarded only to it,
 *      mirroring how `AcrossSwapModule` pins its periphery. Enso recommends using the API's
 *      `tx.to`, so an admin must update `ensoRouter` if Enso ships a new router deployment.
 *
 *      A gateway safe's input may be supplied to Aave, so `executeSwap` runs the lend-gateway
 *      sandwich: it withdraws any shortfall of the input from the safe's Aave position, swaps,
 *      re-supplies a same-chain output delivered to the safe, and takes the health-factor floor.
 *      Every bookend is skipped where `cashModule` is zero (no card spending, no gateway).
 */
contract EnsoSwapModule is ModuleBase, ModuleCheckBalance, ModuleLendGatewaySandwich, UpgradeableProxy, IBridgeModule {
    using MessageHashUtils for bytes32;

    /// @notice User-signed swap intent. One per safe at a time.
    /// @dev For a same-chain swap (`dstChainId == block.chainid`), `dstToken`, `recipient`
    ///      and `minOut` are enforced with a recipient balance-delta check. For cross-chain
    ///      swaps they are carried for the signed intent and events only because settlement
    ///      is non-atomic.
    struct Order {
        address srcToken;
        uint256 srcAmount;
        uint256 dstChainId;
        address dstToken;
        address recipient;
        uint256 minOut;
        uint256 deadline;
    }

    /// @notice Everything `executeSwap` needs, captured at request time: the user-signed
    ///         order, BE-supplied Enso `router`-strategy calldata, and optional native fee.
    /// @dev `swapId` is the stable identifier minted at `requestSwap` and re-emitted at
    ///      execute/cancel so off-chain consumers can link the three lifecycle events of a
    ///      single swap.
    struct StoredSwap {
        Order order;
        bytes swapData;
        bytes32 swapId;
        address target;
        uint256 nativeFee;
    }

    /// @custom:storage-location erc7201:etherfi.storage.EnsoSwapModule
    struct EnsoSwapModuleStorage {
        /// @notice Mapping of safe address to its single active stored swap.
        mapping(address safe => StoredSwap swap) swaps;
        /// @notice Pinned Enso Router address used on this chain; approved and called on every swap.
        address ensoRouter;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.EnsoSwapModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant EnsoSwapModuleStorageLocation = 0x5a12820f7ccffa3b7965b81854504b7b9081737c3d6393e92a0a755ce6314400;

    /// @dev Domain-separator-style prefixes for the digest the user signs.
    bytes32 private constant REQUEST_SWAP_SIG = keccak256("EnsoSwapModule.requestSwap");
    bytes32 private constant REQUEST_SWAP_WITH_NATIVE_FEE_SIG = keccak256("EnsoSwapModule.requestSwapWithNativeFee");
    bytes32 private constant CANCEL_SWAP_SIG = keccak256("EnsoSwapModule.cancelSwap");
    address private constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev `swapId` is the second topic on every lifecycle event so consumers can filter or
    ///      join a swap's request/execute/cancel by id.
    event SwapRequested(address indexed safe, bytes32 indexed swapId, address srcToken, uint256 srcAmount, uint256 dstChainId, address dstToken, address recipient, uint256 minOut, uint256 deadline);
    event NativeFeeRequested(address indexed safe, bytes32 indexed swapId, uint256 nativeFee);
    event SwapExecuted(address indexed safe, bytes32 indexed swapId, uint256 dstChainId, address indexed dstToken, uint256 minOut);
    event SwapCancelled(address indexed safe, bytes32 indexed swapId);
    event EnsoRouterSet(address oldEnsoRouter, address newEnsoRouter);

    /// @notice Reverts when a non-admin tries to set the Enso Router.
    error OnlyAdmin();
    /// @notice Reverts when `requestSwap` is called on a safe with an active swap.
    error OrderAlreadyActive();
    /// @notice Reverts when `executeSwap` / `cancelSwap` finds no stored swap.
    error NoActiveOrder();
    /// @notice Reverts when the user's signature doesn't meet the safe's threshold.
    error InvalidSignatures();
    /// @notice Reverts when `executeSwap` runs after `order.deadline`.
    error OrderExpired();
    /// @notice Reverts when `cancelExpiredSwap` runs at or before `order.deadline`.
    error OrderNotExpired();
    /// @notice Reverts when the admin-set `ensoRouter` is still zero.
    error MissingConfig();
    /// @notice Reverts when `executeSwap` runs before the CashModule withdrawal hold matures.
    error WithdrawalDelayNotElapsed();
    /// @notice Reverts when the order expires before the CashModule withdrawal delay elapses.
    error DeadlineBeforeWithdrawalDelay();
    /// @notice Reverts when CashModule would process the withdrawal immediately.
    error ZeroWithdrawalDelay();
    /// @notice Reverts when the BE-supplied Enso calldata is empty.
    error EmptySwapData();
    /// @notice Reverts when a same-chain swap delivers less than the signed minimum output.
    error InsufficientOutputAmount();
    /// @notice Reverts when the native fee supplied by the keeper differs from the signed fee.
    error InvalidNativeFee();

    /// @dev Immutables (`etherFiDataProvider`, `cashModule` via ModuleCheckBalance) live in the
    ///      IMPLEMENTATION's code — every upgrade impl must be constructed with the same data provider.
    ///      `cashModule` is zero where there is no card spending (and therefore no lend gateway).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        _disableInitializers();
    }

    /**
     * @notice Initialises the proxy.
     * @param _roleRegistry Role registry used for upgrade authority + pause control.
     * @param _ensoRouter Pinned Enso Router address used on this chain.
     */
    function initialize(address _roleRegistry, address _ensoRouter) external initializer {
        __UpgradeableProxy_init(_roleRegistry);

        if (_ensoRouter == address(0)) revert InvalidInput();
        _getEnsoSwapModuleStorage().ensoRouter = _ensoRouter;
    }

    // ---- Admin config ----

    /// @notice Sets the pinned Enso Router address used on this chain.
    function setEnsoRouter(address _ensoRouter) external {
        _onlyAdmin();
        if (_ensoRouter == address(0)) revert InvalidInput();
        EnsoSwapModuleStorage storage $ = _getEnsoSwapModuleStorage();
        emit EnsoRouterSet($.ensoRouter, _ensoRouter);
        $.ensoRouter = _ensoRouter;
    }

    // ---- Views ----

    function getOrder(address safe) external view returns (Order memory) {
        return _getEnsoSwapModuleStorage().swaps[safe].order;
    }

    function getSwap(address safe) external view returns (StoredSwap memory) {
        return _getEnsoSwapModuleStorage().swaps[safe];
    }

    function getEnsoRouter() external view returns (address) {
        return _getEnsoSwapModuleStorage().ensoRouter;
    }

    // ---- Lifecycle ----

    /**
     * @notice Stores a user-signed swap intent for `safe` together with the BE-supplied Enso
     *         `router`-strategy calldata, and places a CashModule solvency hold for the source
     *         amount (if cashModule is installed on this chain). `executeSwap` later replays
     *         exactly what is stored here.
     * @dev One active swap per safe; re-requesting requires cancel-or-execute first. The user
     *      signs over the FULL request — `order` AND the Enso `swapData` — so the keeper cannot
     *      substitute a different swap payload at `executeSwap` than the user authorised.
     */
    function requestSwap(address safe, Order calldata order, bytes calldata swapData, address[] calldata signers, bytes[] calldata signatures) external whenNotPaused onlyEtherFiSafe(safe) {
        _requestSwap(safe, order, swapData, 0, false, signers, signatures);
    }

    /**
     * @notice Native-fee variant of `requestSwap`. On chains with a CashModule hold, the
     *         keeper supplies the signed fee later to `executeSwap`. Without a CashModule,
     *         execution is immediate and the fee must accompany this request.
     */
    function requestSwapWithNativeFee(address safe, Order calldata order, bytes calldata swapData, uint256 nativeFee, address[] calldata signers, bytes[] calldata signatures) external payable whenNotPaused onlyEtherFiSafe(safe) {
        if (nativeFee == 0) revert InvalidNativeFee();
        // A native-fee refund and native swap output are indistinguishable in the safe's
        // balance delta, so this combination cannot enforce minOut accurately.
        if (order.dstChainId == block.chainid && order.dstToken == NATIVE_TOKEN && order.recipient == safe) {
            revert InvalidNativeFee();
        }
        if (address(cashModule) != address(0) && msg.value != 0) revert InvalidNativeFee();
        _requestSwap(safe, order, swapData, nativeFee, true, signers, signatures);
    }

    function _requestSwap(address safe, Order calldata order, bytes calldata swapData, uint256 nativeFee, bool withNativeFee, address[] calldata signers, bytes[] calldata signatures) internal {
        _validateRequest(safe, order, swapData);

        uint256 nonce = IEtherFiSafe(safe).useNonce();
        _verifyRequestSignature(safe, order, swapData, nativeFee, withNativeFee, nonce, signers, signatures);
        _storeAndDispatch(safe, order, swapData, nativeFee, nonce);
    }

    /// @dev Shared request validation, split out to keep `requestSwap` under the legacy stack limit.
    function _validateRequest(address safe, Order calldata order, bytes calldata swapData) internal view {
        EnsoSwapModuleStorage storage $ = _getEnsoSwapModuleStorage();
        if (swapData.length == 0) revert EmptySwapData();
        if (order.srcToken == address(0) || order.srcAmount == 0 || order.recipient == address(0) || order.deadline <= block.timestamp) revert InvalidInput();
        if (order.dstChainId == block.chainid && (order.dstToken == address(0) || order.minOut == 0)) {
            revert InvalidInput();
        }
        if ($.swaps[safe].order.srcToken != address(0)) revert OrderAlreadyActive();
        if ($.ensoRouter == address(0)) revert MissingConfig();
        if (address(cashModule) != address(0)) {
            (uint64 withdrawalDelay,,) = cashModule.getDelays();
            if (withdrawalDelay == 0) revert ZeroWithdrawalDelay();
            if (order.deadline <= block.timestamp + withdrawalDelay) revert DeadlineBeforeWithdrawalDelay();
        }
    }

    /// @dev Stores the verified swap and either places the CashModule hold (OP) or executes
    ///      immediately (mainnet, where `cashModule == 0`).
    function _storeAndDispatch(address safe, Order calldata order, bytes calldata swapData, uint256 nativeFee, uint256 nonce) internal {
        EnsoSwapModuleStorage storage $ = _getEnsoSwapModuleStorage();
        bytes32 swapId = keccak256(abi.encode(block.chainid, address(this), safe, nonce, order));
        $.swaps[safe] = StoredSwap({ order: order, swapData: swapData, swapId: swapId, target: $.ensoRouter, nativeFee: nativeFee });

        _emitSwapRequested(safe, swapId, order);
        if (nativeFee != 0) emit NativeFeeRequested(safe, swapId, nativeFee);

        if (address(cashModule) != address(0)) {
            cashModule.requestWithdrawalByModule(safe, order.srcToken, order.srcAmount);
        } else {
            executeSwap(safe);
        }
    }

    function _emitSwapRequested(address safe, bytes32 swapId, Order calldata order) internal {
        emit SwapRequested(safe, swapId, order.srcToken, order.srcAmount, order.dstChainId, order.dstToken, order.recipient, order.minOut, order.deadline);
    }

    /**
     * @notice Executes the stored swap for `safe`. It reads the order and Enso calldata
     *         captured at request time, releases the solvency hold, and drives the safe to
     *         approve the pinned Enso Router and forward the calldata and signed native fee.
     * @dev Permissionless: it only replays the swap the user already signed at request time.
     *      Native-fee executions require `msg.value` to exactly match the signed fee, so the
     *      caller funds the route without drawing from or leaving ETH in the safe. Meant to
     *      be called after the CashModule withdrawal delay matures.
     */
    function executeSwap(address safe) public payable nonReentrant whenNotPaused onlyEtherFiSafe(safe) {
        EnsoSwapModuleStorage storage $ = _getEnsoSwapModuleStorage();
        StoredSwap memory swap = $.swaps[safe];
        if (swap.order.srcToken == address(0)) revert NoActiveOrder();
        if (block.timestamp > swap.order.deadline) revert OrderExpired();
        if (swap.target == address(0)) revert MissingConfig();
        if (msg.value != swap.nativeFee) revert InvalidNativeFee();

        if (address(cashModule) != address(0)) {
            if (block.timestamp < cashModule.getData(safe).pendingWithdrawalRequest.finalizeTime) {
                revert WithdrawalDelayNotElapsed();
            }
        }

        delete $.swaps[safe];
        uint256 healthFactorBefore;
        if (address(cashModule) != address(0)) {
            cashModule.cancelWithdrawalByModule(safe);
            // Front bookend: request-time sourcing normally leaves the input loose through the delay;
            // this re-pulls any shortfall from the safe's Aave position and asserts the full input is
            // present before the safe approves the router. Runs after the cancel so the released
            // reservation no longer masks the loose balance.
            healthFactorBefore = _pullAndRequire(safe, swap.order.srcToken, swap.order.srcAmount);
        }

        _dispatchSwap(safe, swap);

        // The input was collateral pulled out of Aave (at request or just above), so the end state must hold
        // the gateway's health-factor floor unless it left the position no worse off than it started.
        if (address(cashModule) != address(0)) _ensureGatewayFloor(safe, healthFactorBefore);

        emit SwapExecuted(safe, swap.swapId, swap.order.dstChainId, swap.order.dstToken, swap.order.minOut);
    }

    /// @dev Approve the signed and snapshotted Enso Router for the input token, forward the
    ///      signed Enso calldata and native fee verbatim, then reset the approval to zero.
    ///      The fee is first sent to the safe because the safe must remain the router's caller.
    function _dispatchSwap(address safe, StoredSwap memory swap) internal {
        address ensoRouter = swap.target;
        bool validateOutput = swap.order.dstChainId == block.chainid;
        uint256 balanceBefore;
        if (validateOutput) {
            balanceBefore = _balanceOf(swap.order.dstToken, swap.order.recipient);
        }

        address[] memory to = new address[](3);
        uint256[] memory values = new uint256[](3);
        bytes[] memory data = new bytes[](3);

        to[0] = swap.order.srcToken;
        data[0] = abi.encodeCall(IERC20.approve, (ensoRouter, swap.order.srcAmount));
        to[1] = ensoRouter;
        values[1] = swap.nativeFee;
        data[1] = swap.swapData;
        to[2] = swap.order.srcToken;
        data[2] = abi.encodeCall(IERC20.approve, (ensoRouter, 0));

        if (swap.nativeFee != 0) Address.sendValue(payable(safe), swap.nativeFee);
        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);

        if (validateOutput) {
            uint256 balanceAfter = _balanceOf(swap.order.dstToken, swap.order.recipient);
            if (balanceAfter < balanceBefore || balanceAfter - balanceBefore < swap.order.minOut) revert InsufficientOutputAmount();
            // Back bookend: a same-chain output delivered to the safe goes back into Aave as
            // collateral (best-effort, no-op for an unregistered asset or a non-gateway safe).
            // Cross-chain settlement is non-atomic and a third-party recipient's funds have left
            // the safe, so there is nothing to resupply on those routes.
            if (swap.order.recipient == safe && address(cashModule) != address(0)) {
                _resupplyToGateway(safe, swap.order.dstToken, balanceAfter - balanceBefore);
            }
        }
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        if (token == NATIVE_TOKEN) return account.balance;
        return IERC20(token).balanceOf(account);
    }

    /**
     * @notice Cancels the stored swap for `safe`. Delegates to `cancelWithdrawalByModule` on
     *         `cashModule` which calls back into `cancelBridgeByCashModule` — that callback
     *         clears state and emits.
     * @dev Signed by the safe's owners (same threshold as `requestSwap`). The user's BE-down
     *      escape hatch. Where `cashModule == 0` clears state directly.
     */
    function cancelSwap(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        EnsoSwapModuleStorage storage $ = _getEnsoSwapModuleStorage();
        if ($.swaps[safe].order.srcToken == address(0)) revert NoActiveOrder();

        uint256 nonce = IEtherFiSafe(safe).useNonce();
        bytes32 digest = _cancelDigest(safe, nonce);
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignatures();

        bytes32 swapId = $.swaps[safe].swapId;
        if (address(cashModule) != address(0)) {
            cashModule.cancelWithdrawalByModule(safe);
        } else {
            // When cashModule is set, cancelWithdrawalByModule calls cancelBridgeByCashModule
            // which clears the swap; where cashModule == 0 we clear it here directly.
            delete $.swaps[safe];
            emit SwapCancelled(safe, swapId);
        }
    }

    /**
     * @notice Permissionlessly cancels an EXPIRED stored swap for `safe`, releasing its
     *         CashModule solvency hold WITHOUT an owner signature.
     * @dev Once `block.timestamp > order.deadline`, `executeSwap` can never succeed again (it
     *      reverts `OrderExpired`), so the stored swap and its hold would otherwise sit until an
     *      owner signs `cancelSwap`. Authorization is purely the elapsed deadline: this can only
     *      run after expiry, and it merely refunds the safe's own funds back to the safe (via
     *      `cancelWithdrawalByModule`) and clears state — there is no fund-movement authority to
     *      abuse, so it is safe to let the backend keeper (or anyone) call it. Mirrors
     *      `cancelSwap`'s clearing path; where `cashModule == 0` state is cleared directly.
     */
    function cancelExpiredSwap(address safe) external nonReentrant onlyEtherFiSafe(safe) {
        EnsoSwapModuleStorage storage $ = _getEnsoSwapModuleStorage();
        StoredSwap memory swap = $.swaps[safe];
        if (swap.order.srcToken == address(0)) revert NoActiveOrder();
        if (block.timestamp <= swap.order.deadline) revert OrderNotExpired();

        if (address(cashModule) != address(0)) {
            cashModule.cancelWithdrawalByModule(safe);
        } else {
            delete $.swaps[safe];
            emit SwapCancelled(safe, swap.swapId);
        }
    }

    /**
     * @notice Hook called by `CashModule.cancelWithdrawalByModule` to keep our state in sync.
     *         Clears the stored swap and emits if one is still present. No-op if already
     *         cleared (`executeSwap` deletes its own swap before calling the cancel hook).
     */
    function cancelBridgeByCashModule(address safe) external override {
        if (msg.sender != address(cashModule)) revert Unauthorized();
        EnsoSwapModuleStorage storage $ = _getEnsoSwapModuleStorage();
        if ($.swaps[safe].order.srcToken == address(0)) return;
        bytes32 swapId = $.swaps[safe].swapId;
        delete $.swaps[safe];
        emit SwapCancelled(safe, swapId);
    }

    // ---- Internals ----

    /// @dev Verifies the user's signature over the FULL request — the order AND the Enso
    ///      `swapData` — consuming a safe nonce so a signed request can't replay. Binding
    ///      `swapData` means the keeper cannot substitute a different swap payload than the
    ///      user actually authorised.
    function _verifyRequestSignature(address safe, Order calldata order, bytes calldata swapData, uint256 nativeFee, bool withNativeFee, uint256 nonce, address[] calldata signers, bytes[] calldata signatures) internal view {
        bytes32 digest = withNativeFee ? _requestWithNativeFeeDigest(safe, order, swapData, nativeFee, nonce) : _requestDigest(safe, order, swapData, nonce);
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignatures();
    }

    /// @dev Legacy zero-native-fee digest, retained so existing integrations keep working after upgrade.
    function _requestDigest(address safe, Order calldata order, bytes calldata swapData, uint256 nonce) internal view returns (bytes32) {
        address target = _getEnsoSwapModuleStorage().ensoRouter;
        return keccak256(abi.encodePacked(REQUEST_SWAP_SIG, block.chainid, address(this), nonce, safe, abi.encode(order), keccak256(swapData), target)).toEthSignedMessageHash();
    }

    /// @dev Native-fee digest binds the exact keeper-funded value to the user authorization.
    function _requestWithNativeFeeDigest(address safe, Order calldata order, bytes calldata swapData, uint256 nativeFee, uint256 nonce) internal view returns (bytes32) {
        address target = _getEnsoSwapModuleStorage().ensoRouter;
        return keccak256(abi.encodePacked(REQUEST_SWAP_WITH_NATIVE_FEE_SIG, block.chainid, address(this), nonce, safe, abi.encode(order), keccak256(swapData), target, nativeFee)).toEthSignedMessageHash();
    }

    /// @dev Digest the safe owners sign to cancel the active swap, bound to the safe nonce.
    function _cancelDigest(address safe, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(CANCEL_SWAP_SIG, block.chainid, address(this), nonce, safe)).toEthSignedMessageHash();
    }

    function _onlyAdmin() internal view {
        IRoleRegistry(etherFiDataProvider.roleRegistry()).onlyAdminTimelock(msg.sender);
    }

    function _getEnsoSwapModuleStorage() internal pure returns (EnsoSwapModuleStorage storage $) {
        assembly {
            $.slot := EnsoSwapModuleStorageLocation
        }
    }
}
