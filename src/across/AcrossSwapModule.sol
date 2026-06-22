// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ICashModule } from "../interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { ISpokePool } from "../interfaces/ISpokePool.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title AcrossSwapModule
 * @author ether.fi
 * @notice Cross-chain Buy module installed on the OP `EtherFiSafe`. The user signs ONE
 *         intent at `requestSwap`, which also stores the BE-supplied Across deposit args
 *         and destination `message`. After the CashModule withdrawal delay matures the
 *         keeper calls `executeSwap(safe)` — taking only the safe address — which replays
 *         the stored swap verbatim: it releases the solvency hold and drives the safe to
 *         call `SpokePool.depositV3`. The safe is the depositor, so source-chain refunds
 *         auto-land at the safe.
 * @dev The Across destination-side `message` (MulticallHandler `Instructions` payload) and
 *      the deposit args are built off-chain by the BE and stored at request time, then
 *      forwarded verbatim — there is no on-chain sandwich enforcement. Off-chain monitoring
 *      catches BE bugs or mis-routing.
 *
 *      On the OP deploy the module hooks `CashModule.requestWithdrawalByModule` /
 *      `cancelWithdrawalByModule` to place a solvency hold for the duration of the
 *      CashModule withdrawal delay. Where the data provider's `cashModule` is the zero
 *      address the hold mechanic is skipped.
 *
 *      Per-chain config (SpokePool, MulticallHandler) is admin-set; the module is otherwise
 *      stateless across safes apart from the one-active-swap-per-safe map.
 */
contract AcrossSwapModule is ModuleBase, UpgradeableProxy {
    using MessageHashUtils for bytes32;

    /// @notice User-signed swap intent. One per safe at a time.
    struct Order {
        address srcToken;
        uint256 srcAmount;
        uint256 dstChainId;
        address dstToken;
        address recipient;
        uint256 minOut;
        uint256 deadline;
    }

    /// @notice BE-supplied deposit args. `outputAmount` carries the relayer commitment
    ///         Across quoted; validated against `order.minOut` at request time.
    struct DepositArgs {
        uint256 outputAmount;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        address exclusiveRelayer;
    }

    /// @notice Everything `executeSwap` needs, captured at `requestSwap`: the user-signed
    ///         order plus the BE-supplied deposit args and destination multicall message.
    /// @dev `swapId` is the stable identifier minted at `requestSwap` and re-emitted at
    ///      execute/cancel so off-chain consumers can link the three lifecycle events of a
    ///      single swap. Appended last to keep the upgradeable storage layout stable.
    struct StoredSwap {
        Order order;
        DepositArgs depositArgs;
        bytes message;
        bytes32 swapId;
    }

    /// @custom:storage-location erc7201:etherfi.storage.AcrossSwapModule
    struct AcrossSwapModuleStorage {
        /// @notice Mapping of safe address to its single active stored swap.
        mapping(address safe => StoredSwap swap) swaps;
        /// @notice SpokePool address used on this chain.
        address spokePool;
        /// @notice MulticallHandler address used as the destination recipient on every `depositV3` call.
        address multicallHandler;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.AcrossSwapModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AcrossSwapModuleStorageLocation = 0x59f3e7eaaef5f4e4dfa17cb74cd92a8efd7c6a7e08e5b3e1da26c8dec61cda00;

    /// @notice Role allowed to configure per-chain constants (`spokePool`,
    ///         `multicallHandler`).
    bytes32 public constant ACROSS_SWAP_MODULE_ADMIN_ROLE = keccak256("ACROSS_SWAP_MODULE_ADMIN_ROLE");

    /// @dev Domain-separator-style prefixes for the digest the user signs.
    bytes32 private constant REQUEST_SWAP_SIG = keccak256("AcrossSwapModule.requestSwap");
    bytes32 private constant CANCEL_SWAP_SIG = keccak256("AcrossSwapModule.cancelSwap");

    /// @notice CashModule on the same chain. Zero where there is no card spending.
    ICashModule public immutable cashModule;

    /// @dev `swapId` is the second topic on every lifecycle event so consumers can filter or
    ///      join a swap's request/execute/cancel by id. `srcToken` / `dstChainId` are no longer
    ///      indexed to stay within the 3-topic limit; both remain in the event data.
    event SwapRequested(
        address indexed safe,
        bytes32 indexed swapId,
        address srcToken,
        uint256 srcAmount,
        uint256 dstChainId,
        address dstToken,
        address recipient,
        uint256 minOut,
        uint256 deadline
    );
    event SwapExecuted(
        address indexed safe,
        bytes32 indexed swapId,
        uint256 dstChainId,
        address indexed dstToken,
        uint256 outputAmount
    );
    event SwapCancelled(address indexed safe, bytes32 indexed swapId);
    event SpokePoolSet(address oldSpokePool, address newSpokePool);
    event MulticallHandlerSet(address oldMulticallHandler, address newMulticallHandler);

    /// @notice Reverts when a non-admin tries to set per-chain constants.
    error OnlyAdmin();
    /// @notice Reverts when `requestSwap` is called on a safe with an active swap.
    error OrderAlreadyActive();
    /// @notice Reverts when `executeSwap` / `cancelSwap` finds no stored swap.
    error NoActiveOrder();
    /// @notice Reverts when the user's signature doesn't meet the safe's threshold.
    error InvalidSignatures();
    /// @notice Reverts when `executeSwap` runs after `order.deadline`.
    error OrderExpired();
    /// @notice Reverts when `depositArgs.outputAmount < order.minOut`.
    error InsufficientOutputAmount();
    /// @notice Reverts when admin-set `spokePool` / `multicallHandler` is still zero.
    error MissingConfig();
    /// @notice Reverts when `executeSwap` runs before the CashModule withdrawal hold matures.
    error WithdrawalDelayNotElapsed();

    /// @dev Immutables (`etherFiDataProvider`, `cashModule`) live in the IMPLEMENTATION's
    ///      code — every upgrade impl must be constructed with the same data provider.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) {
        cashModule = ICashModule(IEtherFiDataProvider(_etherFiDataProvider).getCashModule());
        _disableInitializers();
    }

    /**
     * @notice Initialises the proxy.
     * @param _roleRegistry Role registry used for upgrade authority + pause control.
     */
    function initialize(address _roleRegistry, address _spokePool, address _multicallHandler) external initializer {
        __UpgradeableProxy_init(_roleRegistry);

        if (_spokePool == address(0) || _multicallHandler == address(0)) revert InvalidInput();
        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        $.spokePool = _spokePool;
        $.multicallHandler = _multicallHandler;
    }

    // ---- Admin config ----

    /// @notice Sets the Across `SpokePool` address used on this chain.
    function setSpokePool(address _spokePool) external {
        _onlyAdmin();
        if (_spokePool == address(0)) revert InvalidInput();
        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        emit SpokePoolSet($.spokePool, _spokePool);
        $.spokePool = _spokePool;
    }

    /// @notice Sets the Across `MulticallHandler` address used as the destination
    ///         recipient on every `depositV3` call.
    function setMulticallHandler(address _multicallHandler) external {
        _onlyAdmin();
        if (_multicallHandler == address(0)) revert InvalidInput();
        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        emit MulticallHandlerSet($.multicallHandler, _multicallHandler);
        $.multicallHandler = _multicallHandler;
    }

    // ---- Views ----

    function getOrder(address safe) external view returns (Order memory) {
        return _getAcrossSwapModuleStorage().swaps[safe].order;
    }

    function getSwap(address safe) external view returns (StoredSwap memory) {
        return _getAcrossSwapModuleStorage().swaps[safe];
    }

    function getSpokePool() external view returns (address) {
        return _getAcrossSwapModuleStorage().spokePool;
    }

    function getMulticallHandler() external view returns (address) {
        return _getAcrossSwapModuleStorage().multicallHandler;
    }

    // ---- Lifecycle ----

    /**
     * @notice Stores a user-signed swap intent for `safe` together with the BE-supplied
     *         Across deposit args and destination `message`, and places a CashModule
     *         solvency hold for the source amount (if cashModule is installed on this
     *         chain). `executeSwap` later replays exactly what is stored here.
     * @dev One active swap per safe; re-requesting requires cancel-or-execute first. The
     *      user signs over the FULL request — `order`, `depositArgs`, AND the destination
     *      `message` — so the keeper cannot substitute a different destination payload or
     *      relayer/quote terms at `executeSwap` than the user authorised.
     */
    function requestSwap(
        address safe,
        Order calldata order,
        DepositArgs calldata depositArgs,
        bytes calldata message,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external whenNotPaused onlyEtherFiSafe(safe) {
        if (
            order.srcToken == address(0) || order.srcAmount == 0 ||
            order.dstToken == address(0) || order.dstChainId == 0 ||
            order.recipient == address(0) || order.minOut == 0 ||
            order.deadline <= block.timestamp
        ) revert InvalidInput();
        if (depositArgs.outputAmount < order.minOut) revert InsufficientOutputAmount();

        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        if ($.swaps[safe].order.srcToken != address(0)) revert OrderAlreadyActive();
        if ($.spokePool == address(0) || $.multicallHandler == address(0)) revert MissingConfig();

        uint256 nonce = IEtherFiSafe(safe).useNonce();
        _verifyRequestSignature(safe, order, depositArgs, message, nonce, signers, signatures);

        bytes32 swapId = keccak256(abi.encode(block.chainid, address(this), safe, nonce, order));
        $.swaps[safe] = StoredSwap({ order: order, depositArgs: depositArgs, message: message, swapId: swapId });

        _emitSwapRequested(safe, swapId, order);

        if (address(cashModule) != address(0)) {
            cashModule.requestWithdrawalByModule(safe, order.srcToken, order.srcAmount);
        } else {
            executeSwap(safe);
        }
    }

    function _emitSwapRequested(address safe, bytes32 swapId, Order calldata order) internal {
        emit SwapRequested(
            safe,
            swapId,
            order.srcToken,
            order.srcAmount,
            order.dstChainId,
            order.dstToken,
            order.recipient,
            order.minOut,
            order.deadline
        );
    }

    /**
     * @notice Executes the stored swap for `safe`. Takes only the safe address: it reads
     *         the order, deposit args and message captured at `requestSwap`, releases the
     *         solvency hold, and drives the safe to call `SpokePool.depositV3`. Safe is the
     *         depositor → source-chain refunds auto-land at the safe.
     * @dev Permissionless: it only replays the swap the user already signed at `requestSwap`
     *      (order + depositArgs + message are all bound into that signature), so any caller
     *      can do no more than execute exactly what the user authorised. Meant to be called
     *      after the CashModule withdrawal delay matures.
     */
    function executeSwap(address safe) public nonReentrant whenNotPaused onlyEtherFiSafe(safe) {
        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        StoredSwap memory swap = $.swaps[safe];
        if (swap.order.srcToken == address(0)) revert NoActiveOrder();
        if (block.timestamp > swap.order.deadline) revert OrderExpired();
        if ($.spokePool == address(0) || $.multicallHandler == address(0)) revert MissingConfig();

        if (address(cashModule) != address(0)) {
            if (block.timestamp < cashModule.getData(safe).pendingWithdrawalRequest.finalizeTime) {
                revert WithdrawalDelayNotElapsed();
            }
        }

        delete $.swaps[safe];
        if (address(cashModule) != address(0)) cashModule.cancelWithdrawalByModule(safe);

        _dispatchDeposit(safe, swap.order, swap.depositArgs, swap.message);

        emit SwapExecuted(safe, swap.swapId, swap.order.dstChainId, swap.order.dstToken, swap.depositArgs.outputAmount);
    }

    function _dispatchDeposit(
        address safe,
        Order memory order,
        DepositArgs memory depositArgs,
        bytes memory message
    ) internal {
        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        bytes memory depositData = _encodeDepositV3(safe, $.multicallHandler, order, depositArgs, message);
        address spokePool = $.spokePool;

        address[] memory to = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory data = new bytes[](2);

        to[0] = order.srcToken;
        data[0] = abi.encodeCall(IERC20.approve, (spokePool, order.srcAmount));
        to[1] = spokePool;
        data[1] = depositData;

        IEtherFiSafe(safe).execTransactionFromModule(to, values, data);
    }

    /// @dev Encoded separately to dodge stack-too-deep on the 12-arg `depositV3` call.
    function _encodeDepositV3(
        address safe,
        address multicallHandler,
        Order memory order,
        DepositArgs memory depositArgs,
        bytes memory message
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ISpokePool.depositV3,
            (
                safe,
                multicallHandler,
                order.srcToken,
                order.dstToken,
                order.srcAmount,
                depositArgs.outputAmount,
                order.dstChainId,
                depositArgs.exclusiveRelayer,
                depositArgs.quoteTimestamp,
                depositArgs.fillDeadline,
                depositArgs.exclusivityDeadline,
                message
            )
        );
    }

    /**
     * @notice Cancels the stored swap for `safe`. Delegates to `cancelWithdrawalByModule`
     *         on `cashModule` which calls back into `cancelBridgeByCashModule` — that
     *         callback clears state and emits.
     * @dev Signed by the safe's owners (same threshold as `requestSwap`). The user's
     *      BE-down escape hatch. Where `cashModule == 0` clears state directly.
     */
    function cancelSwap(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        if ($.swaps[safe].order.srcToken == address(0)) revert NoActiveOrder();

        bytes32 digest = keccak256(
            abi.encodePacked(CANCEL_SWAP_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe)
        ).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignatures();

        bytes32 swapId = $.swaps[safe].swapId;
        if (address(cashModule) != address(0)) {
            cashModule.cancelWithdrawalByModule(safe);
        } else {
            // the if block cancelWithdrawalByModule calls the cancelBridgeByCashModule function 
            // and cancels the swap already, so we need to delete the swap only in else block
            delete $.swaps[safe];
            emit SwapCancelled(safe, swapId);
        }
    }

    /**
     * @notice Hook called by `CashModule.cancelWithdrawalByModule` to keep our state in
     *         sync. Clears the stored swap and emits if one is still present. No-op if
     *         already cleared (`executeSwap` deletes its own swap before calling the
     *         cancel hook).
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != address(cashModule)) revert Unauthorized();
        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        if ($.swaps[safe].order.srcToken == address(0)) return;
        bytes32 swapId = $.swaps[safe].swapId;
        delete $.swaps[safe];
        emit SwapCancelled(safe, swapId);
    }

    // ---- Internals ----

    /// @dev Extracted from `requestSwap` to keep that function's stack budget under the
    ///      legacy codegen limit. Verifies the user's signature over the FULL request —
    ///      the order AND the BE-supplied `depositArgs` + destination `message` — consuming
    ///      a safe nonce so a signed request can't replay. Binding `message` and
    ///      `depositArgs` means the keeper cannot substitute a different destination payload
    ///      (`message` decides where the bridged funds land) or different relayer/quote
    ///      terms than the user actually authorised. The off-chain signer must therefore
    ///      sign over `(order, depositArgs, message)`.
    function _verifyRequestSignature(
        address safe,
        Order calldata order,
        DepositArgs calldata depositArgs,
        bytes calldata message,
        uint256 nonce,
        address[] calldata signers,
        bytes[] calldata signatures
    ) internal view {
        bytes32 digest = keccak256(
            abi.encodePacked(
                REQUEST_SWAP_SIG,
                block.chainid,
                address(this),
                nonce,
                safe,
                abi.encode(order),
                keccak256(abi.encode(depositArgs)),
                keccak256(message)
            )
        ).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignatures();
    }

    function _onlyAdmin() internal view {
        if (!IRoleRegistry(etherFiDataProvider.roleRegistry()).hasRole(ACROSS_SWAP_MODULE_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
    }

    function _getAcrossSwapModuleStorage() internal pure returns (AcrossSwapModuleStorage storage $) {
        assembly {
            $.slot := AcrossSwapModuleStorageLocation
        }
    }
}
