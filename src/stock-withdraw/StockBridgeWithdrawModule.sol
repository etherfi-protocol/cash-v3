// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { IBackedCCIPBridge } from "../interfaces/IBackedCCIPBridge.sol";
import { IBridgeModule } from "../interfaces/IBridgeModule.sol";
import { ICashModule, WithdrawalRequest } from "../interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../interfaces/IEtherFiDataProvider.sol";
import { IEtherFiSafe } from "../interfaces/IEtherFiSafe.sol";
import { EnumerableAddressWhitelistLib } from "../libraries/EnumerableAddressWhitelistLib.sol";
import { ModuleBase } from "../modules/ModuleBase.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title StockBridgeWithdrawModule
 * @notice Withdraws a safe's wrapped stock to an address on another chain over Backed's bridge. The user signs one
 *         intent `(wrapper, amount, recipient, deadline)`, which places a CashModule withdrawal hold with this module
 *         as recipient. Once the delay matures anyone can execute it: the wrapper lands here, is redeemed to the raw
 *         stock and sent over the bridge, which pays the raw stock to the recipient on the destination from custody.
 *         The bridge fee is paid from this module's native balance. An order past its deadline is released back to
 *         the safe by anyone; nothing ever leaves the safe for an expired order.
 * @author ether.fi
 */
contract StockBridgeWithdrawModule is ModuleBase, UpgradeableProxy, IBridgeModule {
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using EnumerableAddressWhitelistLib for EnumerableSetLib.AddressSet;

    /// @notice User-signed withdrawal intent, one per safe at a time
    struct Order {
        address wrapper;
        uint256 amount;
        address recipient;
        uint256 deadline;
    }

    struct StoredWithdrawal {
        Order order;
        bytes32 withdrawalId;
    }

    /// @custom:storage-location erc7201:etherfi.storage.StockBridgeWithdrawModule
    struct StockBridgeWithdrawModuleStorage {
        mapping(address safe => StoredWithdrawal withdrawal) withdrawals;
        /// @notice Wrappers this module may redeem and bridge
        EnumerableSetLib.AddressSet supportedWrappers;
        IBackedCCIPBridge bridge;
        /// @notice Bridge selector of the chain the raw stock is delivered on
        uint64 destinationSelector;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.StockBridgeWithdrawModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StockBridgeWithdrawModuleStorageLocation = 0xdd3298e6f4d32205a99b9ca023a85e53b87d2a5507442e5b970eb6b8d2261300;

    ICashModule public immutable cashModule;

    /// @notice Role that configures wrappers and the bridge and withdraws the native fee float
    bytes32 public constant STOCK_BRIDGE_WITHDRAW_MODULE_ADMIN_ROLE = keccak256("STOCK_BRIDGE_WITHDRAW_MODULE_ADMIN_ROLE");

    bytes32 private constant REQUEST_WITHDRAWAL_SIG = keccak256("StockBridgeWithdrawModule.requestWithdrawal");
    bytes32 private constant CANCEL_WITHDRAWAL_SIG = keccak256("StockBridgeWithdrawModule.cancelWithdrawal");

    event WithdrawalRequested(address indexed safe, bytes32 indexed withdrawalId, address wrapper, uint256 amount, address recipient, uint256 deadline);
    event WithdrawalExecuted(address indexed safe, bytes32 indexed withdrawalId, address wrapper, uint256 amount, uint256 rawAmount, address recipient, bytes32 messageId);
    event WithdrawalCancelled(address indexed safe, bytes32 indexed withdrawalId);
    event WrappersConfigured(address[] wrappers, bool[] supported);
    event BridgeSet(address bridge, uint64 destinationSelector);
    event NativeWithdrawn(address indexed to, uint256 amount);

    error TokenNotSupported();
    error TokenNotOnBridge();
    error OrderAlreadyActive();
    error NoActiveOrder();
    error InvalidSignatures();
    error OrderExpired();
    error OrderNotExpired();
    error InsufficientNativeFee();
    error NativeTransferFailed();
    error CannotFindMatchingWithdrawal();
    error MissingConfig();
    error ZeroWithdrawalDelay();
    error DeadlineBeforeWithdrawalDelay();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _etherFiDataProvider) ModuleBase(_etherFiDataProvider) {
        cashModule = ICashModule(IEtherFiDataProvider(_etherFiDataProvider).getCashModule());
        _disableInitializers();
    }

    /// @notice Sets up the proxy with the role registry, the bridge and the destination chain selector
    function initialize(address _roleRegistry, address _bridge, uint64 _destinationSelector) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        _setBridge(_bridge, _destinationSelector);
    }

    // ---- Admin ----

    /**
     * @notice Registers or removes wrappers; a registered wrapper's raw stock must be known to the bridge
     * @param wrappers Wrapper tokens
     * @param supported Support flag per wrapper
     */
    function configureWrappers(address[] calldata wrappers, bool[] calldata supported) external onlyRole(STOCK_BRIDGE_WITHDRAW_MODULE_ADMIN_ROLE) {
        StockBridgeWithdrawModuleStorage storage $ = _getStorage();
        uint256 len = wrappers.length;
        if (len != supported.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < len; ++i) {
            if (supported[i] && $.bridge.tokenIds(IERC4626(wrappers[i]).asset()) == 0) revert TokenNotOnBridge();
        }
        $.supportedWrappers.configure(wrappers, supported);
        emit WrappersConfigured(wrappers, supported);
    }

    /**
     * @notice Sets the bridge and the destination chain selector used for every order
     * @param _bridge Backed's bridge on this chain
     * @param _destinationSelector Selector of the chain the raw stock is delivered on
     */
    function setBridge(address _bridge, uint64 _destinationSelector) external onlyRole(STOCK_BRIDGE_WITHDRAW_MODULE_ADMIN_ROLE) {
        _setBridge(_bridge, _destinationSelector);
    }

    /**
     * @notice Withdraws native balance from the fee float
     * @param to Recipient
     * @param amount Amount, 0 for the whole balance
     */
    function withdrawNative(address to, uint256 amount) external onlyRole(STOCK_BRIDGE_WITHDRAW_MODULE_ADMIN_ROLE) {
        if (to == address(0)) revert InvalidInput();
        if (amount == 0) amount = address(this).balance;
        (bool success,) = payable(to).call{ value: amount }("");
        if (!success) revert NativeTransferFailed();
        emit NativeWithdrawn(to, amount);
    }

    // ---- Views ----

    /// @notice The safe's open order, empty if it has none
    function getOrder(address safe) external view returns (Order memory) {
        return _getStorage().withdrawals[safe].order;
    }

    /// @notice The safe's open order with the CashModule withdrawal id it is bound to
    function getWithdrawal(address safe) external view returns (StoredWithdrawal memory) {
        return _getStorage().withdrawals[safe];
    }

    /// @notice Whether orders may be placed for this wrapper
    function isWrapperSupported(address wrapper) external view returns (bool) {
        return _getStorage().supportedWrappers.contains(wrapper);
    }

    /// @notice Every wrapper orders may be placed for
    function getSupportedWrappers() external view returns (address[] memory) {
        return _getStorage().supportedWrappers.values();
    }

    /// @notice The bridge and destination chain selector every order is sent with
    function getBridge() external view returns (address, uint64) {
        StockBridgeWithdrawModuleStorage storage $ = _getStorage();
        return (address($.bridge), $.destinationSelector);
    }

    /**
     * @notice Quotes the native bridge fee for the stored withdrawal, priced on the raw stock the redeem would return
     * @param safe The safe whose stored withdrawal to quote
     * @return feeToken Always `ETH`
     * @return amount The native fee `executeWithdrawal` will spend from this module's balance
     */
    function getWithdrawalFee(address safe) external view returns (address feeToken, uint256 amount) {
        StockBridgeWithdrawModuleStorage storage $ = _getStorage();
        Order memory order = $.withdrawals[safe].order;
        if (order.wrapper == address(0)) revert NoActiveOrder();
        IERC4626 wrapper = IERC4626(order.wrapper);
        uint256 fee = $.bridge.getDeliveryFeeCost($.destinationSelector, _receiver(order.recipient), wrapper.asset(), wrapper.previewRedeem(order.amount), "");
        return (ETH, fee);
    }

    // ---- Lifecycle ----

    /**
     * @notice Stores a user-signed withdrawal intent for `safe` and places a CashModule withdrawal hold with this
     *         module as recipient. CashModule sources the wrapper from the lend gateway if it is supplied there.
     * @param safe The safe withdrawing
     * @param order The user-signed withdrawal intent
     * @param signers Safe owners that signed the request digest
     * @param signatures Signatures corresponding to `signers`
     */
    function requestWithdrawal(address safe, Order calldata order, address[] calldata signers, bytes[] calldata signatures) external nonReentrant whenNotPaused onlyEtherFiSafe(safe) {
        _validateRequest(safe, order);

        uint256 nonce = IEtherFiSafe(safe).useNonce();
        if (!IEtherFiSafe(safe).checkSignatures(_requestDigest(safe, order, nonce), signers, signatures)) revert InvalidSignatures();

        bytes32 withdrawalId = keccak256(abi.encode(block.chainid, address(this), safe, nonce, order));
        _getStorage().withdrawals[safe] = StoredWithdrawal({ order: order, withdrawalId: withdrawalId });
        _emitRequested(safe, withdrawalId, order);

        cashModule.requestWithdrawalByModule(safe, order.wrapper, order.amount);
    }

    /**
     * @notice Executes the stored withdrawal for `safe`: processes the matured CashModule withdrawal, redeems the
     *         wrapper to raw stock and sends it over the bridge to the recipient. Anyone may call; the bridge fee
     *         comes from this module's native balance, which `msg.value` tops up.
     * @param safe The safe whose stored withdrawal to execute
     */
    function executeWithdrawal(address safe) external payable nonReentrant whenNotPaused onlyEtherFiSafe(safe) {
        StockBridgeWithdrawModuleStorage storage $ = _getStorage();
        StoredWithdrawal memory withdrawal = $.withdrawals[safe];
        Order memory order = withdrawal.order;
        if (order.wrapper == address(0)) revert NoActiveOrder();
        if (block.timestamp > order.deadline) revert OrderExpired();
        // Re-checked so removing a wrapper halts orders already in flight; their hold stays releasable
        if (!$.supportedWrappers.contains(order.wrapper)) revert TokenNotSupported();

        WithdrawalRequest memory pending = cashModule.getData(safe).pendingWithdrawalRequest;
        if (pending.recipient != address(this) || pending.tokens.length != 1 || pending.tokens[0] != order.wrapper || pending.amounts[0] != order.amount) {
            revert CannotFindMatchingWithdrawal();
        }

        delete $.withdrawals[safe];
        cashModule.processWithdrawal(safe);

        // The raw stock rebases, so measure what the redeem actually delivered
        address raw = IERC4626(order.wrapper).asset();
        uint256 rawBefore = IERC20(raw).balanceOf(address(this));
        IERC4626(order.wrapper).redeem(order.amount, address(this), address(this));
        uint256 rawAmount = IERC20(raw).balanceOf(address(this)) - rawBefore;

        bytes32 receiver = _receiver(order.recipient);
        uint256 fee = $.bridge.getDeliveryFeeCost($.destinationSelector, receiver, raw, rawAmount, "");
        if (address(this).balance < fee) revert InsufficientNativeFee();
        IERC20(raw).forceApprove(address($.bridge), rawAmount);
        bytes32 messageId = $.bridge.send{ value: fee }($.destinationSelector, receiver, raw, rawAmount, "");

        emit WithdrawalExecuted(safe, withdrawal.withdrawalId, order.wrapper, order.amount, rawAmount, order.recipient, messageId);
    }

    /**
     * @notice Cancels the stored withdrawal for `safe`, releasing the CashModule hold; signed by the safe's owners
     * @param safe The safe whose stored withdrawal to cancel
     * @param signers Safe owners that signed the cancel digest
     * @param signatures Signatures corresponding to `signers`
     */
    function cancelWithdrawal(address safe, address[] calldata signers, bytes[] calldata signatures) external nonReentrant onlyEtherFiSafe(safe) {
        if (_getStorage().withdrawals[safe].order.wrapper == address(0)) revert NoActiveOrder();

        bytes32 digest = keccak256(abi.encodePacked(CANCEL_WITHDRAWAL_SIG, block.chainid, address(this), IEtherFiSafe(safe).useNonce(), safe)).toEthSignedMessageHash();
        if (!IEtherFiSafe(safe).checkSignatures(digest, signers, signatures)) revert InvalidSignatures();

        cashModule.cancelWithdrawalByModule(safe);
    }

    /**
     * @notice Releases the CashModule hold of an order past its deadline; no signature needed since the wrapper only
     *         ever goes back to the safe
     * @param safe The safe whose expired withdrawal to cancel
     */
    function cancelExpiredWithdrawal(address safe) external nonReentrant onlyEtherFiSafe(safe) {
        Order memory order = _getStorage().withdrawals[safe].order;
        if (order.wrapper == address(0)) revert NoActiveOrder();
        if (block.timestamp <= order.deadline) revert OrderNotExpired();

        cashModule.cancelWithdrawalByModule(safe);
    }

    /// @inheritdoc IBridgeModule
    function cancelBridgeByCashModule(address safe) external {
        if (msg.sender != address(cashModule)) revert Unauthorized();
        StockBridgeWithdrawModuleStorage storage $ = _getStorage();
        if ($.withdrawals[safe].order.wrapper == address(0)) return;
        bytes32 withdrawalId = $.withdrawals[safe].withdrawalId;
        delete $.withdrawals[safe];
        emit WithdrawalCancelled(safe, withdrawalId);
    }

    /// @notice Accepts native funding for the bridge fee float
    receive() external payable { }

    // ---- Internals ----

    /// @dev Reverts unless the order is complete, the wrapper supported, the safe has no open order and the deadline outlasts the withdrawal delay
    function _validateRequest(address safe, Order calldata order) internal view {
        StockBridgeWithdrawModuleStorage storage $ = _getStorage();
        if (order.amount == 0 || order.recipient == address(0)) revert InvalidInput();
        if (!$.supportedWrappers.contains(order.wrapper)) revert TokenNotSupported();
        if ($.withdrawals[safe].order.wrapper != address(0)) revert OrderAlreadyActive();
        if (address($.bridge) == address(0)) revert MissingConfig();

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        if (withdrawalDelay == 0) revert ZeroWithdrawalDelay();
        if (order.deadline <= block.timestamp + withdrawalDelay) revert DeadlineBeforeWithdrawalDelay();
    }

    /// @dev The message the safe owners sign for a request, bound to this chain, this module, the nonce and the safe
    function _requestDigest(address safe, Order calldata order, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(REQUEST_WITHDRAWAL_SIG, block.chainid, address(this), nonce, safe, abi.encode(order))).toEthSignedMessageHash();
    }

    /// @dev Split out of `requestWithdrawal` to stay under the stack limit
    function _emitRequested(address safe, bytes32 withdrawalId, Order calldata order) internal {
        emit WithdrawalRequested(safe, withdrawalId, order.wrapper, order.amount, order.recipient, order.deadline);
    }

    /// @dev Stores the bridge and destination chain selector, both required
    function _setBridge(address _bridge, uint64 _destinationSelector) internal {
        if (_bridge == address(0) || _destinationSelector == 0) revert InvalidInput();
        StockBridgeWithdrawModuleStorage storage $ = _getStorage();
        $.bridge = IBackedCCIPBridge(_bridge);
        $.destinationSelector = _destinationSelector;
        emit BridgeSet(_bridge, _destinationSelector);
    }

    /// @dev The recipient in the bytes32 form the bridge takes
    function _receiver(address recipient) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(recipient)));
    }

    /// @dev The module's ERC-7201 storage
    function _getStorage() private pure returns (StockBridgeWithdrawModuleStorage storage $) {
        assembly {
            $.slot := StockBridgeWithdrawModuleStorageLocation
        }
    }
}
