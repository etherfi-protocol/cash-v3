// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";
import { EnumerableMapLib } from "solady/utils/EnumerableMapLib.sol";

import { IBridgeModule } from "../interfaces/IBridgeModule.sol";
import { EnumerableAddressWhitelistLib } from "../libraries/EnumerableAddressWhitelistLib.sol";
import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { IRoleRegistry } from "../interfaces/IRoleRegistry.sol";
import { IOFT, MessagingFee, OFTReceipt, SendParam } from "../interfaces/IOFT.sol";
import { WithdrawalRequest } from "../interfaces/ICashModule.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";
import { ModuleCheckBalance } from "../modules/ModuleCheckBalance.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title StockWithdrawModule
 * @author ether.fi
 * @notice Cross-chain wrapped-stock withdrawal module installed on the OP `EtherFiSafe`. The
 *         user signs ONE intent at `requestWithdrawal` — `(iToken, amount, minReturn, deadline,
 *         recipient, dstEid)` — which places a CashModule withdrawal hold (recipient = this module).
 *         After the withdrawal delay matures, the permissionless, payable
 *         `executeWithdrawal(safe)` processes the withdrawal (iTOKEN lands here) and OFT-sends
 *         it to the mainnet `StockUnwrapper` with a composeMsg carrying the order terms. On
 *         Ethereum the unwrapper redeems the Backed ERC-4626 wrapper to `recipient` (reverting
 *         if output < `minReturn`, which parks the LZ compose message for retry) or, past
 *         `deadline`, delivers the wrapped token to the user's deterministic TradingSafe.
 * @dev Funds route through the module (Stargate pattern) because the OFT send needs
 *      `msg.value` for the LayerZero fee, which the execute caller supplies — that cannot be
 *      injected into a safe-originated call. iTOKENs are ShadowOFTs (the OFT IS the token,
 *      mint/burn), so no residual approvals are left behind.
 *
 *      OFT `minAmountLD` only guards shared-decimal dust rounding (set from `quoteOFT`);
 *      economic slippage protection is exclusively `minReturn`, enforced against the actual
 *      redeem output on Ethereum.
 */
contract StockWithdrawModule is ModuleBase, ModuleCheckBalance, UpgradeableProxy, IBridgeModule {
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using EnumerableMapLib for EnumerableMapLib.Uint256ToAddressMap;
    using EnumerableAddressWhitelistLib for EnumerableSetLib.AddressSet;

    /// @notice User-signed withdrawal intent. One per safe at a time.
    /// @dev `minReturn` is denominated in the UNDERLYING stock (e.g. SPYx), not the wrapper.
    ///      `deadline` is evaluated on the destination chain at lzCompose time (and gates
    ///      execute here). `dstEid` is the user-chosen destination endpoint; the unwrapper
    ///      for it is resolved from `stockUnwrappers[dstEid]` at execute time.
    struct Order {
        address iToken;
        uint256 amount;
        uint256 minReturn;
        uint256 deadline;
        address recipient;
        uint32 dstEid;
    }

    /// @notice Everything `executeWithdrawal` needs, captured at `requestWithdrawal`.
    /// @dev The unwrapper address and `composeGasLimit` are deliberately NOT snapshotted:
    ///      they are read live at execute time (keyed by the signed `order.dstEid`) so the
    ///      admin can repoint a redeployed unwrapper or bump compose gas for in-flight orders
    ///      without users having to cancel and re-sign. The admin role and the module's
    ///      upgrade authority sit behind the same role registry, so snapshotting would add
    ///      no real protection.
    struct StoredWithdrawal {
        Order order;
        bytes32 withdrawalId;
    }

    /// @custom:storage-location erc7201:etherfi.storage.StockWithdrawModule
    struct StockWithdrawModuleStorage {
        /// @notice Mapping of safe address to its single active stored withdrawal.
        mapping(address safe => StoredWithdrawal withdrawal) withdrawals;
        /// @notice Enumerable set of wrapped-stock ShadowOFTs (iTOKENs) this module may bridge.
        EnumerableSetLib.AddressSet supportedTokens;
        /// @notice Enumerable map of destination endpoint ID => `StockUnwrapper` composed receiver.
        EnumerableMapLib.Uint256ToAddressMap stockUnwrappers;
        /// @notice Executor gas limit for the destination lzCompose call.
        uint128 composeGasLimit;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.StockWithdrawModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StockWithdrawModuleStorageLocation = 0x79b068f9b079c00932ab348c89f00dce3855a0360decf75df1474e5e0fccf900;

    /// @notice Role allowed to configure supported tokens, destination and compose gas.
    bytes32 public constant STOCK_WITHDRAW_MODULE_ADMIN_ROLE = keccak256("STOCK_WITHDRAW_MODULE_ADMIN_ROLE");

    /// @dev Domain-separator-style prefixes for the digests the user signs.
    bytes32 private constant REQUEST_WITHDRAWAL_SIG = keccak256("StockWithdrawModule.requestWithdrawal");
    bytes32 private constant CANCEL_WITHDRAWAL_SIG = keccak256("StockWithdrawModule.cancelWithdrawal");

    /**
     * @notice Emitted when a withdrawal is requested.
     * @param safe The safe that requested the withdrawal.
     * @param withdrawalId The ID of the withdrawal.
     * @param iToken The iToken that is being withdrawn.
     * @param amount The amount of the iToken that is being withdrawn.
     * @param minReturn The minimum return that is expected from the withdrawal.
     * @param deadline The deadline for the withdrawal.
     * @param recipient The recipient of the withdrawal.
     */
    event WithdrawalRequested(address indexed safe, bytes32 indexed withdrawalId, address iToken, uint256 amount, uint256 minReturn, uint256 deadline, address recipient);

    /**
     * @notice Emitted when a withdrawal is executed.
     * @param safe The safe that executed the withdrawal.
     * @param withdrawalId The ID of the withdrawal.
     * @param iToken The iToken that is being withdrawn.
     * @param amount The amount of the iToken that is being withdrawn.
     * @param recipient The recipient of the withdrawal.
     */
    event WithdrawalExecuted(address indexed safe, bytes32 indexed withdrawalId, address iToken, uint256 amount, address recipient);

    /**
     * @notice Emitted when a withdrawal is cancelled.
     * @param safe The safe that cancelled the withdrawal.
     * @param withdrawalId The ID of the withdrawal.
     */
    event WithdrawalCancelled(address indexed safe, bytes32 indexed withdrawalId);

    /**
     * @notice Emitted when tokens are configured.
     * @param iTokens The iTokens that are being configured.
     * @param supported Whether the iTokens are supported.
     */
    event TokensConfigured(address[] iTokens, bool[] supported);

    /**
     * @notice Emitted when unwrappers are configured for destination endpoints.
     * @param dstEids The destination endpoint IDs.
     * @param unwrappers The StockUnwrapper for each endpoint (zero disables the route).
     */
    event UnwrappersConfigured(uint32[] dstEids, address[] unwrappers);

    /**
     * @notice Emitted when the compose gas limit is set.
     * @param oldGasLimit The old compose gas limit.
     * @param newGasLimit The new compose gas limit.
     */
    event ComposeGasLimitSet(uint128 oldGasLimit, uint128 newGasLimit);

    /// @notice Reverts when a non-admin calls an admin function.
    error OnlyAdmin();
    /// @notice Reverts when the iToken is not on the supported list.
    error TokenNotSupported();
    /// @notice Reverts when a supported iToken is not its own OFT (ShadowOFT invariant).
    error InvalidOFT();
    /// @notice Reverts when `requestWithdrawal` is called on a safe with an active order.
    error OrderAlreadyActive();
    /// @notice Reverts when execute/cancel finds no stored withdrawal.
    error NoActiveOrder();
    /// @notice Reverts when the user's signature doesn't meet the safe's threshold.
    error InvalidSignatures();
    /// @notice Reverts when `executeWithdrawal` runs after `order.deadline`.
    error OrderExpired();
    /// @notice Reverts when `cancelExpiredWithdrawal` runs at or before `order.deadline`.
    error OrderNotExpired();
    /// @notice Reverts when `msg.value` doesn't cover the quoted LayerZero native fee.
    error InsufficientNativeFee();
    /// @notice Reverts when refunding excess `msg.value` to the caller fails.
    error NativeTransferFailed();
    /// @notice Reverts when the pending CashModule withdrawal doesn't match the stored order.
    error CannotFindMatchingWithdrawal();
    /// @notice Reverts when destination config (dstEid / unwrapper / composeGas) is unset.
    error MissingConfig();
    /// @notice Reverts when CashModule would process the withdrawal immediately.
    error ZeroWithdrawalDelay();
    /// @notice Reverts when the order expires before the CashModule withdrawal delay elapses.
    error DeadlineBeforeWithdrawalDelay();

    /// @dev Immutables (`etherFiDataProvider`, `cashModule`) live in the IMPLEMENTATION's code —
    ///      every upgrade impl must be constructed with the same data provider.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) ModuleCheckBalance(_etherFiDataProvider) {
        _disableInitializers();
    }

    /**
     * @notice Initialises the proxy with the full module config. Any of the config arrays may
     *         be empty and set later via the admin setters (requests revert `MissingConfig` /
     *         `TokenNotSupported` until the route they need is configured).
     * @param _roleRegistry Role registry (upgrade authority + pause control + admin role).
     * @param _composeGasLimit Executor gas for the destination lzCompose call.
     * @param _iTokens Wrapped-stock ShadowOFTs to register.
     * @param _supported Support flag per iToken; same length as `_iTokens`.
     * @param _dstEids Destination endpoint IDs to configure unwrappers for.
     * @param _unwrappers StockUnwrapper per endpoint; same length as `_dstEids`.
     */
    function initialize(
        address _roleRegistry,
        uint128 _composeGasLimit,
        address[] calldata _iTokens,
        bool[] calldata _supported,
        uint32[] calldata _dstEids,
        address[] calldata _unwrappers
    ) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        _setComposeGasLimit(_composeGasLimit);
        if (_iTokens.length > 0) _configureTokens(_iTokens, _supported);
        if (_dstEids.length > 0) _configureUnwrappers(_dstEids, _unwrappers);
    }

    // ---- Admin config ----

    /**
     * @notice Registers/unregisters wrapped-stock ShadowOFTs. Enforces the ShadowOFT
     *         invariant `IOFT(iToken).token() == iToken` on registration.
     * @param iTokens Array of iToken addresses to configure.
     * @param supported Support flag per iToken; same length as `iTokens`.
     * @custom:throws OnlyAdmin If the caller lacks `STOCK_WITHDRAW_MODULE_ADMIN_ROLE`.
     * @custom:throws ArrayLengthMismatch If the arrays diverge in length or are empty.
     * @custom:throws InvalidInput If any iToken address is zero.
     * @custom:throws InvalidOFT If a registered iToken is not its own OFT.
     */
    function configureTokens(address[] calldata iTokens, bool[] calldata supported) external {
        _onlyAdmin();
        _configureTokens(iTokens, supported);
    }

    /**
     * @notice Sets the StockUnwrapper per destination endpoint. A zero unwrapper disables
     *         new requests for that endpoint.
     * @param dstEids Destination endpoint IDs to configure.
     * @param unwrappers StockUnwrapper per endpoint; same length as `dstEids`.
     * @custom:throws OnlyAdmin If the caller lacks `STOCK_WITHDRAW_MODULE_ADMIN_ROLE`.
     * @custom:throws ArrayLengthMismatch If the arrays diverge in length or are empty.
     * @custom:throws InvalidInput If any endpoint ID is zero.
     */
    function configureUnwrappers(uint32[] calldata dstEids, address[] calldata unwrappers) external {
        _onlyAdmin();
        _configureUnwrappers(dstEids, unwrappers);
    }

    /**
     * @notice Sets the executor gas limit for the destination lzCompose call. Read live at
     *         execute time (not snapshotted) so admins can bump gas for stuck sends.
     * @param _composeGasLimit The new executor gas limit; must be non-zero.
     * @custom:throws OnlyAdmin If the caller lacks `STOCK_WITHDRAW_MODULE_ADMIN_ROLE`.
     * @custom:throws InvalidInput If the gas limit is zero.
     */
    function setComposeGasLimit(uint128 _composeGasLimit) external {
        _onlyAdmin();
        _setComposeGasLimit(_composeGasLimit);
    }

    // ---- Views ----

    /**
     * @notice Returns the active order for a safe (zeroed struct if none).
     * @param safe The safe to query.
     * @return The stored user-signed order.
     */
    function getOrder(address safe) external view returns (Order memory) {
        return _getStockWithdrawModuleStorage().withdrawals[safe].order;
    }

    /**
     * @notice Returns the full stored withdrawal for a safe (zeroed struct if none).
     * @param safe The safe to query.
     * @return The stored withdrawal (order + withdrawalId).
     */
    function getWithdrawal(address safe) external view returns (StoredWithdrawal memory) {
        return _getStockWithdrawModuleStorage().withdrawals[safe];
    }

    /**
     * @notice Returns whether an iToken is registered for bridging.
     * @param iToken The ShadowOFT address to query.
     * @return True if the token is supported.
     */
    function isTokenSupported(address iToken) external view returns (bool) {
        return _getStockWithdrawModuleStorage().supportedTokens.contains(iToken);
    }

    /**
     * @notice Returns all registered wrapped-stock ShadowOFTs.
     * @return The supported iToken addresses.
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return _getStockWithdrawModuleStorage().supportedTokens.values();
    }

    /**
     * @notice Returns the StockUnwrapper configured for a destination endpoint.
     * @param dstEid The destination endpoint ID to query.
     * @return The unwrapper address (zero if the route is not configured).
     */
    function getStockUnwrapper(uint32 dstEid) external view returns (address) {
        (, address unwrapper) = _getStockWithdrawModuleStorage().stockUnwrappers.tryGet(uint256(dstEid));
        return unwrapper;
    }

    /**
     * @notice Returns every configured destination route.
     * @return dstEids The configured destination endpoint IDs.
     * @return unwrappers The StockUnwrapper for each endpoint; same order as `dstEids`.
     */
    function getConfiguredUnwrappers() external view returns (uint32[] memory dstEids, address[] memory unwrappers) {
        EnumerableMapLib.Uint256ToAddressMap storage map = _getStockWithdrawModuleStorage().stockUnwrappers;
        uint256 len = map.length();
        dstEids = new uint32[](len);
        unwrappers = new address[](len);
        for (uint256 i = 0; i < len;) {
            (uint256 dstEid, address unwrapper) = map.at(i);
            dstEids[i] = uint32(dstEid);
            unwrappers[i] = unwrapper;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Returns the executor gas limit used for the destination lzCompose call.
     * @return The compose gas limit.
     */
    function getComposeGasLimit() external view returns (uint128) {
        return _getStockWithdrawModuleStorage().composeGasLimit;
    }

    /**
     * @notice Quotes the LayerZero native fee for the stored withdrawal.
     * @param safe The safe whose stored withdrawal to quote.
     * @return feeToken Always `Constants.ETH`.
     * @return amount The native fee the `executeWithdrawal` caller must supply.
     * @custom:throws NoActiveOrder If the safe has no stored withdrawal.
     * @custom:throws MissingConfig If the order's destination route was disabled.
     */
    function getWithdrawalFee(address safe) external view returns (address feeToken, uint256 amount) {
        StoredWithdrawal memory withdrawal = _getStockWithdrawModuleStorage().withdrawals[safe];
        if (withdrawal.order.iToken == address(0)) revert NoActiveOrder();
        MessagingFee memory fee = IOFT(withdrawal.order.iToken).quoteSend(_buildSendParam(safe, withdrawal), false);
        return (ETH, fee.nativeFee);
    }

    // ---- Lifecycle ----

    /**
     * @notice Stores a user-signed withdrawal intent for `safe` and places a CashModule
     *         withdrawal hold with this module as recipient. CashModule sources the iTOKEN
     *         from the Aave lend gateway if it is currently supplied as collateral.
     * @dev One active withdrawal per safe. The signature binds the full order (including the
     *      destination `dstEid`); the unwrapper for that endpoint is resolved live from
     *      storage at execute time.
     * @param safe Address of the EtherFiSafe withdrawing.
     * @param order The user-signed withdrawal intent.
     * @param signers Safe owners that signed the request digest.
     * @param signatures Signatures corresponding to `signers`.
     * @custom:throws InvalidSignatures If the signatures don't meet the safe's threshold.
     * @custom:throws OrderAlreadyActive If the safe already has a stored withdrawal.
     * @custom:throws TokenNotSupported If `order.iToken` is not registered.
     * @custom:throws MissingConfig If no unwrapper is configured for `order.dstEid`.
     * @custom:throws DeadlineBeforeWithdrawalDelay If the deadline can't outlive the delay.
     */
    function requestWithdrawal(address safe, Order calldata order, address[] calldata signers, bytes[] calldata signatures) external nonReentrant whenNotPaused onlyEtherFiSafe(safe) {
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        _validateRequest($, safe, order);

        uint256 nonce = IEtherFiSafe(safe).useNonce();
        if (!IEtherFiSafe(safe).checkSignatures(_requestDigest(safe, order, nonce), signers, signatures)) revert InvalidSignatures();

        bytes32 withdrawalId = keccak256(abi.encode(block.chainid, address(this), safe, nonce, order));
        $.withdrawals[safe] = StoredWithdrawal({ order: order, withdrawalId: withdrawalId });

        emit WithdrawalRequested(safe, withdrawalId, order.iToken, order.amount, order.minReturn, order.deadline, order.recipient);

        cashModule.requestWithdrawalByModule(safe, order.iToken, order.amount);
    }

    /**
     * @notice Executes the stored withdrawal for `safe`: processes the matured CashModule
     *         withdrawal (iTOKEN lands in this module) and OFT-sends it to the mainnet
     *         unwrapper with the composed order terms.
     * @dev Permissionless and payable: any caller merely replays what the user signed and
     *      pays the LayerZero native fee (`getWithdrawalFee`); excess msg.value is refunded.
     *      CashModule enforces the withdrawal delay inside `processWithdrawal`.
     * @param safe Address of the EtherFiSafe whose stored withdrawal to execute.
     * @custom:throws NoActiveOrder If the safe has no stored withdrawal.
     * @custom:throws OrderExpired If the order deadline has passed (use `cancelExpiredWithdrawal`).
     * @custom:throws CannotFindMatchingWithdrawal If the CashModule hold doesn't match the order.
     * @custom:throws InsufficientNativeFee If `msg.value` doesn't cover the LayerZero fee.
     */
    function executeWithdrawal(address safe) external payable nonReentrant whenNotPaused onlyEtherFiSafe(safe) {
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        StoredWithdrawal memory withdrawal = $.withdrawals[safe];
        if (withdrawal.order.iToken == address(0)) revert NoActiveOrder();
        if (block.timestamp > withdrawal.order.deadline) revert OrderExpired();

        WithdrawalRequest memory pending = cashModule.getData(safe).pendingWithdrawalRequest;
        if (pending.recipient != address(this) || pending.tokens.length != 1 || pending.tokens[0] != withdrawal.order.iToken || pending.amounts[0] != withdrawal.order.amount) {
            revert CannotFindMatchingWithdrawal();
        }

        delete $.withdrawals[safe];
        cashModule.processWithdrawal(safe);

        _sendOft(safe, withdrawal);

        emit WithdrawalExecuted(safe, withdrawal.withdrawalId, withdrawal.order.iToken, withdrawal.order.amount, withdrawal.order.recipient);
    }

    /**
     * @notice Cancels the stored withdrawal for `safe`, releasing the CashModule hold.
     *         Signed by the safe's owners (same threshold as `requestWithdrawal`).
     * @dev `cancelWithdrawalByModule` calls back into `cancelBridgeByCashModule`, which
     *      clears state and emits.
     * @param safe Address of the EtherFiSafe whose stored withdrawal to cancel.
     * @param signers Safe owners that signed the cancel digest.
     * @param signatures Signatures corresponding to `signers`.
     * @custom:throws NoActiveOrder If the safe has no stored withdrawal.
     * @custom:throws InvalidSignatures If the signatures don't meet the safe's threshold.
     */
    function cancelWithdrawal(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        if ($.withdrawals[safe].order.iToken == address(0)) revert NoActiveOrder();

        bytes32 digest = keccak256(abi.encodePacked(CANCEL_WITHDRAWAL_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignatures();

        cashModule.cancelWithdrawalByModule(safe);
    }

    /**
     * @notice Permissionlessly cancels an EXPIRED stored withdrawal, releasing its CashModule
     *         hold WITHOUT an owner signature.
     * @dev Once `block.timestamp > order.deadline`, `executeWithdrawal` can never succeed
     *      again, so the hold would otherwise sit until an owner signs. Authorization is
     *      purely the elapsed deadline: this merely releases the safe's own funds back to the
     *      safe — no fund-movement authority to abuse.
     * @param safe Address of the EtherFiSafe whose expired withdrawal to cancel.
     * @custom:throws NoActiveOrder If the safe has no stored withdrawal.
     * @custom:throws OrderNotExpired If the deadline has not passed yet.
     */
    function cancelExpiredWithdrawal(address safe) external nonReentrant onlyEtherFiSafe(safe) {
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        StoredWithdrawal memory withdrawal = $.withdrawals[safe];
        if (withdrawal.order.iToken == address(0)) revert NoActiveOrder();
        if (block.timestamp <= withdrawal.order.deadline) revert OrderNotExpired();

        cashModule.cancelWithdrawalByModule(safe);
    }

    /**
     * @notice Hook called by `CashModule.cancelWithdrawalByModule` to keep our state in sync.
     *         Clears the stored withdrawal and emits if one is still present. No-op if already
     *         cleared (`executeWithdrawal` deletes its own record before processing).
     * @param safe Address of the EtherFiSafe whose stored withdrawal to clear.
     * @custom:throws Unauthorized If the caller is not the CashModule.
     */
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != address(cashModule)) revert Unauthorized();
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        if ($.withdrawals[safe].order.iToken == address(0)) return;
        bytes32 withdrawalId = $.withdrawals[safe].withdrawalId;
        delete $.withdrawals[safe];
        emit WithdrawalCancelled(safe, withdrawalId);
    }

    /// @notice Accepts LayerZero fee refunds.
    receive() external payable { }

    // ---- Internals ----

    /// @dev Split out of `requestWithdrawal` to stay under the legacy stack limit.
    function _validateRequest(StockWithdrawModuleStorage storage $, address safe, Order calldata order) internal view {
        if (order.amount == 0 || order.recipient == address(0) || order.minReturn == 0 || order.deadline <= block.timestamp) revert InvalidInput();
        if (!$.supportedTokens.contains(order.iToken)) revert TokenNotSupported();
        if ($.withdrawals[safe].order.iToken != address(0)) revert OrderAlreadyActive();
        (, address unwrapper) = $.stockUnwrappers.tryGet(uint256(order.dstEid));
        if (unwrapper == address(0) || $.composeGasLimit == 0 || address(cashModule) == address(0)) revert MissingConfig();

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        if (withdrawalDelay == 0) revert ZeroWithdrawalDelay();
        if (order.deadline <= block.timestamp + withdrawalDelay) revert DeadlineBeforeWithdrawalDelay();
    }

    /// @dev Digest the safe owners sign over the full order (incl. `dstEid`), bound to the
    ///      safe nonce for replay protection.
    function _requestDigest(address safe, Order calldata order, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            REQUEST_WITHDRAWAL_SIG,
            block.chainid,
            address(this),
            nonce,
            safe,
            abi.encode(order)
        )).toEthSignedMessageHash();
    }

    /// @dev Builds the SendParam for the stored withdrawal. The unwrapper is resolved LIVE
    ///      from `stockUnwrappers[order.dstEid]` (reverting `MissingConfig` if the route was
    ///      disabled after request). `minAmountLD` starts at the full amount and is tightened
    ///      to `quoteOFT`'s `amountReceivedLD` at send time (dust rounding only — economic
    ///      slippage is `minReturn`, enforced on the destination chain).
    function _buildSendParam(address safe, StoredWithdrawal memory withdrawal) internal view returns (SendParam memory) {
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        (, address unwrapper) = $.stockUnwrappers.tryGet(uint256(withdrawal.order.dstEid));
        if (unwrapper == address(0)) revert MissingConfig();

        return SendParam({
            dstEid: withdrawal.order.dstEid,
            to: bytes32(uint256(uint160(unwrapper))),
            amountLD: withdrawal.order.amount,
            minAmountLD: withdrawal.order.amount,
            extraOptions: _lzComposeOptions($.composeGasLimit),
            composeMsg: abi.encode(safe, withdrawal.order.recipient, withdrawal.order.minReturn, withdrawal.order.deadline),
            oftCmd: new bytes(0)
        });
    }

    /// @dev LayerZero TYPE_3 options carrying a single executor lzCompose option — the
    ///      manual equivalent of `OptionsBuilder.newOptions().addExecutorLzComposeOption(0,
    ///      gas, 0)`, inlined to avoid OptionsBuilder's `solidity-bytes-utils` dependency
    ///      (not a tracked submodule). Layout: TYPE_3 (uint16) ‖ workerId=1 (uint8) ‖
    ///      optionLength=19 (uint16) ‖ OPTION_TYPE_LZCOMPOSE=3 (uint8) ‖ index=0 (uint16) ‖
    ///      gas (uint128). optionLength = 1 (type) + 2 (index) + 16 (gas).
    function _lzComposeOptions(uint128 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3), uint8(1), uint16(19), uint8(3), uint16(0), gas);
    }

    /// @dev Shared by `initialize` and `configureTokens`. Validates the ShadowOFT invariant
    ///      (`IOFT(iToken).token() == iToken`) on every registration, then delegates the
    ///      set mutation (zero/duplicate checks included) to `EnumerableAddressWhitelistLib`.
    function _configureTokens(address[] calldata iTokens, bool[] calldata supported) internal {
        uint256 len = iTokens.length;
        if (len == 0 || len != supported.length) revert ArrayLengthMismatch();
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        for (uint256 i = 0; i < len;) {
            if (iTokens[i] == address(0)) revert InvalidInput();
            if (supported[i] && IOFT(iTokens[i]).token() != iTokens[i]) revert InvalidOFT();
            unchecked {
                ++i;
            }
        }
        $.supportedTokens.configure(iTokens, supported);
        emit TokensConfigured(iTokens, supported);
    }

    /// @dev Shared by `initialize` and `configureUnwrappers`. A zero unwrapper removes the
    ///      route (new requests for that eid revert `MissingConfig`).
    function _configureUnwrappers(uint32[] calldata dstEids, address[] calldata unwrappers) internal {
        uint256 len = dstEids.length;
        if (len == 0 || len != unwrappers.length) revert ArrayLengthMismatch();
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        for (uint256 i = 0; i < len;) {
            if (dstEids[i] == 0) revert InvalidInput();
            if (unwrappers[i] == address(0)) $.stockUnwrappers.remove(uint256(dstEids[i]));
            else $.stockUnwrappers.set(uint256(dstEids[i]), unwrappers[i]);
            unchecked {
                ++i;
            }
        }
        emit UnwrappersConfigured(dstEids, unwrappers);
    }

    /// @dev Shared by `initialize` and `setComposeGasLimit`.
    function _setComposeGasLimit(uint128 _composeGasLimit) internal {
        if (_composeGasLimit == 0) revert InvalidInput();
        StockWithdrawModuleStorage storage $ = _getStockWithdrawModuleStorage();
        emit ComposeGasLimitSet($.composeGasLimit, _composeGasLimit);
        $.composeGasLimit = _composeGasLimit;
    }

    /// @dev Quotes, pays and dispatches the OFT send from this module's balance. The caller
    ///      funds the LZ fee; excess is refunded to them (and they are the LZ refund address).
    function _sendOft(address safe, StoredWithdrawal memory withdrawal) internal {
        IOFT oft = IOFT(withdrawal.order.iToken);
        SendParam memory sendParam = _buildSendParam(safe, withdrawal);

        (,, OFTReceipt memory receipt) = oft.quoteOFT(sendParam);
        sendParam.minAmountLD = receipt.amountReceivedLD;

        MessagingFee memory fee = oft.quoteSend(sendParam, false);
        if (msg.value < fee.nativeFee) revert InsufficientNativeFee();

        if (oft.approvalRequired()) IERC20(oft.token()).forceApprove(address(oft), withdrawal.order.amount);
        oft.send{ value: fee.nativeFee }(sendParam, fee, payable(msg.sender));

        uint256 excess = msg.value - fee.nativeFee;
        if (excess > 0) {
            (bool success,) = payable(msg.sender).call{ value: excess }("");
            if (!success) revert NativeTransferFailed();
        }
    }

    /// @dev Reverts unless the caller holds `STOCK_WITHDRAW_MODULE_ADMIN_ROLE`.
    function _onlyAdmin() internal view {
        if (!IRoleRegistry(etherFiDataProvider.roleRegistry()).hasRole(STOCK_WITHDRAW_MODULE_ADMIN_ROLE, msg.sender)) revert OnlyAdmin();
    }

    /// @dev Returns the storage struct from the ERC-7201 namespaced slot.
    function _getStockWithdrawModuleStorage() internal pure returns (StockWithdrawModuleStorage storage $) {
        assembly {
            $.slot := StockWithdrawModuleStorageLocation
        }
    }
}
