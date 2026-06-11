// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ICashModule } from "../interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { ISpokePool } from "../interfaces/ISpokePool.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";

/**
 * @title AcrossSwapModule
 * @author ether.fi
 * @notice Cross-chain swap module installed on `EtherFiSafe` (Buy side, OP) and on
 *         `TradingSafe` (Sell side, mainnet). The user signs ONE EIP-712-style intent
 *         per swap; the keeper drives `executeSwap` after the CashModule delay matures.
 *         No second signature.
 *
 *         At execute time the module validates BE-supplied deposit args against the
 *         stored order, releases the solvency hold, and drives the safe to call
 *         `SpokePool.depositV3`. Safe is the depositor, so source-chain refunds
 *         auto-land at the safe.
 * @dev The Across destination-side `message` (MulticallHandler `Instructions` payload)
 *      is built off-chain by BE and passed through verbatim — there is no on-chain
 *      sandwich enforcement. Off-chain monitoring catches BE bugs or mis-routing.
 *
 *      On the OP deploy the module hooks `CashModule.requestWithdrawalByModule` /
 *      `cancelWithdrawalByModule` to place a solvency hold for the duration of the
 *      CashModule withdrawal delay. On the mainnet TradingSafe deploy the data
 *      provider's `cashModule` is the zero address; the hold mechanic is skipped.
 *
 *      Per-chain config (SpokePool, MulticallHandler) is admin-set; the module is
 *      otherwise stateless across safes apart from the one-active-order-per-safe map.
 */
contract AcrossSwapModule is ModuleBase, ReentrancyGuardTransient {
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

    /// @notice BE-supplied deposit-time args. `outputAmount` carries the relayer
    ///         commitment Across quoted; the module re-validates it against
    ///         `order.minOut`.
    struct DepositArgs {
        uint256 outputAmount;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        address exclusiveRelayer;
    }

    /// @custom:storage-location erc7201:etherfi.storage.AcrossSwapModule
    struct AcrossSwapModuleStorage {
        mapping(address safe => Order order) orders;
        address spokePool;
        address multicallHandler;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.AcrossSwapModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AcrossSwapModuleStorageLocation = 0x59f3e7eaaef5f4e4dfa17cb74cd92a8efd7c6a7e08e5b3e1da26c8dec61cda00;

    /// @notice Role allowed to configure per-chain constants (`spokePool`,
    ///         `multicallHandler`).
    bytes32 public constant ACROSS_SWAP_MODULE_ADMIN_ROLE = keccak256("ACROSS_SWAP_MODULE_ADMIN_ROLE");

    /// @notice Role allowed to call `executeSwap` (held by the BE keeper).
    bytes32 public constant ACROSS_SWAP_MODULE_KEEPER_ROLE = keccak256("ACROSS_SWAP_MODULE_KEEPER_ROLE");

    /// @dev Domain-separator-style prefixes for the digest the user signs.
    bytes32 private constant REQUEST_SWAP_SIG = keccak256("AcrossSwapModule.requestSwap");
    bytes32 private constant CANCEL_SWAP_SIG = keccak256("AcrossSwapModule.cancelSwap");

    /// @notice CashModule on the same chain. Zero on mainnet TradingSafe deploys (no card
    ///         spending → no solvency hold needed).
    ICashModule public immutable cashModule;

    event SwapRequested(
        address indexed safe,
        address indexed srcToken,
        uint256 srcAmount,
        uint256 indexed dstChainId,
        address dstToken,
        address recipient,
        uint256 minOut,
        uint256 deadline
    );
    event SwapExecuted(
        address indexed safe,
        uint256 indexed dstChainId,
        address indexed dstToken,
        uint256 outputAmount
    );
    event SwapCancelled(address indexed safe);
    event SpokePoolSet(address oldSpokePool, address newSpokePool);
    event MulticallHandlerSet(address oldMulticallHandler, address newMulticallHandler);

    /// @notice Reverts when a non-admin tries to set per-chain constants.
    error OnlyAdmin();
    /// @notice Reverts when `executeSwap` is called by a non-keeper.
    error OnlyKeeper();
    /// @notice Reverts when `requestSwap` is called on a safe with an active order.
    error OrderAlreadyActive();
    /// @notice Reverts when `executeSwap` / `cancelSwap` finds no stored order.
    error NoActiveOrder();
    /// @notice Reverts when the user's signature doesn't meet the safe's threshold.
    error InvalidSignatures();
    /// @notice Reverts when `executeSwap` runs after `order.deadline`.
    error OrderExpired();
    /// @notice Reverts when `outputAmount < order.minOut`.
    error InsufficientOutputAmount();
    /// @notice Reverts when admin-set `spokePool` / `multicallHandler` is still zero.
    error MissingConfig();
    /// @notice Reverts when `cancelBridgeByCashModule` is called by anyone but `cashModule`.
    error Unauthorized();

    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) {
        cashModule = ICashModule(IEtherFiDataProvider(_etherFiDataProvider).getCashModule());
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
        return _getAcrossSwapModuleStorage().orders[safe];
    }

    function getSpokePool() external view returns (address) {
        return _getAcrossSwapModuleStorage().spokePool;
    }

    function getMulticallHandler() external view returns (address) {
        return _getAcrossSwapModuleStorage().multicallHandler;
    }

    // ---- Lifecycle ----

    /**
     * @notice Stores a user-signed swap intent for `safe`. Places a CashModule solvency
     *         hold for the source amount (if cashModule is installed on this chain).
     * @dev One active order per safe; re-requesting requires cancel-or-execute first.
     */
    function requestSwap(
        address safe,
        Order calldata order,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external nonReentrant onlyEtherFiSafe(safe) {
        if (
            order.srcToken == address(0) || order.srcAmount == 0 ||
            order.dstToken == address(0) || order.dstChainId == 0 ||
            order.recipient == address(0) || order.minOut == 0 ||
            order.deadline <= block.timestamp
        ) revert InvalidInput();

        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        if ($.orders[safe].srcToken != address(0)) revert OrderAlreadyActive();

        bytes32 digest = keccak256(
            abi.encodePacked(REQUEST_SWAP_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe, abi.encode(order))
        ).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignatures();

        $.orders[safe] = order;

        if (address(cashModule) != address(0)) {
            cashModule.requestWithdrawalByModule(safe, order.srcToken, order.srcAmount);
        }

        emit SwapRequested(
            safe,
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
     * @notice Executes the stored swap for `safe`. Validates BE-supplied `depositArgs`
     *         against the stored order, releases the solvency hold, and drives the safe
     *         to call `SpokePool.depositV3` with `message` forwarded verbatim. Safe is
     *         the depositor → source-chain refunds auto-land at the safe.
     * @dev `ACROSS_SWAP_MODULE_KEEPER_ROLE`-gated. `message` is the BE-built
     *      MulticallHandler `Instructions` blob; the module does not inspect or
     *      validate its content. Off-chain monitoring is the integrity check.
     */
    function executeSwap(
        address safe,
        DepositArgs calldata depositArgs,
        bytes calldata message
    ) external nonReentrant onlyEtherFiSafe(safe) {
        if (!IRoleRegistry(etherFiDataProvider.roleRegistry()).hasRole(ACROSS_SWAP_MODULE_KEEPER_ROLE, msg.sender)) revert OnlyKeeper();

        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        Order memory order = $.orders[safe];
        if (order.srcToken == address(0)) revert NoActiveOrder();
        if (block.timestamp > order.deadline) revert OrderExpired();
        if (depositArgs.outputAmount < order.minOut) revert InsufficientOutputAmount();
        if ($.spokePool == address(0) || $.multicallHandler == address(0)) revert MissingConfig();

        delete $.orders[safe];
        if (address(cashModule) != address(0)) cashModule.cancelWithdrawalByModule(safe);

        _dispatchDeposit(safe, order, depositArgs, message);

        emit SwapExecuted(safe, order.dstChainId, order.dstToken, depositArgs.outputAmount);
    }

    /// @dev Extracted to keep `executeSwap`'s stack budget under the legacy codegen
    ///      limit when the 12-arg `depositV3` is encoded.
    function _dispatchDeposit(
        address safe,
        Order memory order,
        DepositArgs calldata depositArgs,
        bytes calldata message
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
        DepositArgs calldata depositArgs,
        bytes calldata message
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
     *      BE-down escape hatch. On mainnet (where `cashModule == 0`) clears state
     *      directly.
     */
    function cancelSwap(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        if ($.orders[safe].srcToken == address(0)) revert NoActiveOrder();

        bytes32 digest = keccak256(
            abi.encodePacked(CANCEL_SWAP_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe)
        ).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignatures();

        if (address(cashModule) != address(0)) {
            cashModule.cancelWithdrawalByModule(safe);
        } else {
            delete $.orders[safe];
            emit SwapCancelled(safe);
        }
    }

    /**
     * @notice Hook called by `CashModule.cancelWithdrawalByModule` to keep our state in
     *         sync. Clears the stored order and emits if one is still present. No-op if
     *         already cleared (`executeSwap` deletes its own order before calling the
     *         cancel hook).
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != address(cashModule)) revert Unauthorized();
        AcrossSwapModuleStorage storage $ = _getAcrossSwapModuleStorage();
        if ($.orders[safe].srcToken == address(0)) return;
        delete $.orders[safe];
        emit SwapCancelled(safe);
    }

    // ---- Internals ----

    function _onlyAdmin() internal view {
        if (!IRoleRegistry(etherFiDataProvider.roleRegistry()).hasRole(ACROSS_SWAP_MODULE_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
    }

    function _getAcrossSwapModuleStorage() internal pure returns (AcrossSwapModuleStorage storage $) {
        assembly {
            $.slot := AcrossSwapModuleStorageLocation
        }
    }
}
