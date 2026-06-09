// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { OAppCoreUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import { MessagingFee, MessagingReceipt, OAppSenderUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppSenderUpgradeable.sol";

import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { IPriceRelay } from "../interfaces/IPriceRelay.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title PriceRelay
 * @author ether.fi
 * @notice Mainnet-side LayerZero sender. Reads the existing {PriceProvider}
 *         (already normalised to 6-decimal USD) and pushes per-token updates
 *         to an {OracleSink} on the destination chain.
 * @dev Combines the cash-v3 access-control stack ({UpgradeableProxy} +
 *      {IRoleRegistry}) with the LZ OApp sender stack. `OwnableUpgradeable`
 *      (required by LZ for `setPeer`/delegate ops) is initialized to the
 *      role-registry owner / configured delegate.
 *
 *      The LayerZero native fee is paid from this contract's own balance (the
 *      {_payNative} override below), so {poke} is permissionless and non-payable.
 *      To stop a spammer from draining that balance with redundant pokes, a send
 *      only happens for a token once its heartbeat elapsed or its price deviated
 *      past the configured threshold — which also implements the spec's
 *      "every N min, deviation X%" oracle update model on-chain.
 */
contract PriceRelay is IPriceRelay, UpgradeableProxy, OAppSenderUpgradeable {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @custom:storage-location erc7201:etherfi.storage.PriceRelay
    struct PriceRelayStorage {
        /// @notice Mainnet PriceProvider singleton (source of truth)
        IPriceProvider priceProvider;
        /// @notice Destination LayerZero endpoint ID (the OracleSink chain)
        uint32 destinationEid;
        /// @notice LayerZero execution options applied to every relay send
        bytes lzOptions;
        /// @notice Tokens currently subscribed for relay
        EnumerableSetLib.AddressSet subscribed;
        /// @notice Per-token subscription parameters
        mapping(address token => TokenSubscription) subscriptions;
        /// @notice Last price relayed per token (6-decimal USD)
        mapping(address token => uint256) lastSentPrice;
        /// @notice Block timestamp of the last relay per token
        mapping(address token => uint64) lastSentAt;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.PriceRelay")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PriceRelayStorageLocation = 0xa5f763f5f22412144904c62075e838be98e71aa6e5b4ffe579f23d0f3e43c800;

    /// @notice Basis-points denominator (100% = 10_000 bps)
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Role required to subscribe / unsubscribe tokens and configure the relay
    bytes32 public constant PRICE_RELAY_ADMIN_ROLE = keccak256("PRICE_RELAY_ADMIN_ROLE");

    /// @notice Thrown when constructor or initializer receives a zero address
    error InvalidAddress();

    /**
     * @dev Constructor fixes the LZ endpoint for the relay (one per chain).
     *      Forwards into {OAppCoreUpgradeable}, which holds `endpoint` as
     *      immutable.
     * @param _lzEndpoint LayerZero endpoint on mainnet
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint) OAppCoreUpgradeable(_lzEndpoint) {
        if (_lzEndpoint == address(0)) revert InvalidAddress();
        _disableInitializers();
    }

    /**
     * @notice Initializer
     * @param _roleRegistry RoleRegistry contract
     * @param _priceProvider Mainnet PriceProvider singleton
     * @param _delegate LayerZero delegate / OApp owner (e.g. protocol multisig)
     * @param _destinationEid Destination LZ endpoint ID (OracleSink chain)
     */
    function initialize(address _roleRegistry, address _priceProvider, address _delegate, uint32 _destinationEid)
        external
        initializer
    {
        if (_roleRegistry == address(0) || _priceProvider == address(0) || _delegate == address(0)) {
            revert InvalidAddress();
        }
        __UpgradeableProxy_init(_roleRegistry);
        __Ownable_init(_delegate);
        __OAppSender_init(_delegate);

        PriceRelayStorage storage $ = _getStorage();
        $.priceProvider = IPriceProvider(_priceProvider);
        $.destinationEid = _destinationEid;
        emit DestinationEidSet(_destinationEid);
    }

    /// @inheritdoc IPriceRelay
    function subscribe(address token, TokenSubscription calldata config)
        external
        onlyRole(PRICE_RELAY_ADMIN_ROLE)
    {
        if (token == address(0)) revert InvalidInput();

        PriceRelayStorage storage $ = _getStorage();
        $.subscribed.add(token);
        $.subscriptions[token] = config;

        emit TokenSubscribed(token, config);
    }

    /// @inheritdoc IPriceRelay
    function unsubscribe(address token) external onlyRole(PRICE_RELAY_ADMIN_ROLE) {
        PriceRelayStorage storage $ = _getStorage();
        if (!$.subscribed.remove(token)) revert TokenNotSubscribed();
        delete $.subscriptions[token];
        delete $.lastSentPrice[token];
        delete $.lastSentAt[token];
        emit TokenUnsubscribed(token);
    }

    /// @inheritdoc IPriceRelay
    function setLzOptions(bytes calldata options) external onlyRole(PRICE_RELAY_ADMIN_ROLE) {
        _getStorage().lzOptions = options;
        emit LzOptionsSet(options);
    }

    /// @inheritdoc IPriceRelay
    function withdraw(address to, uint256 amount) external onlyRole(PRICE_RELAY_ADMIN_ROLE) {
        if (to == address(0)) revert InvalidInput();
        if (address(this).balance < amount) revert InsufficientBalance();
        (bool ok, ) = to.call{ value: amount }("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawn(to, amount);
    }

    /// @inheritdoc IPriceRelay
    function poke(address[] calldata tokens) external whenNotPaused nonReentrant {
        if (tokens.length == 0) revert InvalidInput();
        PriceRelayStorage storage $ = _getStorage();
        if ($.destinationEid == 0) revert DestinationNotSet();

        uint256 len = tokens.length;
        address[] memory outTokens = new address[](len);
        uint256[] memory outPrices = new uint256[](len);
        uint256 count;

        for (uint256 i = 0; i < len;) {
            address token = tokens[i];
            if (!$.subscribed.contains(token)) revert TokenNotSubscribed();

            uint256 currentPrice = $.priceProvider.price(token);
            TokenSubscription memory sub = $.subscriptions[token];

            bool heartbeatDue = block.timestamp - $.lastSentAt[token] >= sub.heartbeat;
            if (heartbeatDue || _deviated($.lastSentPrice[token], currentPrice, sub.deviationBps)) {
                outTokens[count] = token;
                outPrices[count] = currentPrice;
                unchecked {
                    ++count;
                }
            }

            unchecked {
                ++i;
            }
        }

        if (count == 0) revert NothingToRelay();

        // Shrink the in-memory arrays to the number of qualifying tokens.
        assembly {
            mstore(outTokens, count)
            mstore(outPrices, count)
        }

        bytes memory payload = abi.encode(outTokens, outPrices, uint64(block.timestamp));
        MessagingFee memory fee = _quote($.destinationEid, payload, $.lzOptions, false);
        if (address(this).balance < fee.nativeFee) revert InsufficientBalance();

        _lzSend($.destinationEid, payload, $.lzOptions, MessagingFee(fee.nativeFee, 0), address(this));

        for (uint256 i = 0; i < count;) {
            $.lastSentPrice[outTokens[i]] = outPrices[i];
            $.lastSentAt[outTokens[i]] = uint64(block.timestamp);
            unchecked {
                ++i;
            }
        }

        emit PricesRelayed($.destinationEid, outTokens, outPrices);
    }

    /// @inheritdoc IPriceRelay
    function quote(address[] calldata tokens)
        external
        view
        returns (uint256 nativeFee, uint256 lzTokenFee)
    {
        if (tokens.length == 0) revert InvalidInput();
        PriceRelayStorage storage $ = _getStorage();
        if ($.destinationEid == 0) revert DestinationNotSet();

        // Upper-bound quote: price the payload as if every provided token were relayed.
        uint256[] memory prices = new uint256[](tokens.length);
        bytes memory payload = abi.encode(tokens, prices, uint64(0));
        MessagingFee memory fee = _quote($.destinationEid, payload, $.lzOptions, false);
        return (fee.nativeFee, fee.lzTokenFee);
    }

    /// @inheritdoc IPriceRelay
    function subscriptionOf(address token) external view returns (TokenSubscription memory) {
        return _getStorage().subscriptions[token];
    }

    /// @inheritdoc IPriceRelay
    function lastRelayed(address token) external view returns (uint256 price, uint64 timestamp) {
        PriceRelayStorage storage $ = _getStorage();
        return ($.lastSentPrice[token], $.lastSentAt[token]);
    }

    /// @inheritdoc IPriceRelay
    function lzOptions() external view returns (bytes memory) {
        return _getStorage().lzOptions;
    }

    /// @inheritdoc IPriceRelay
    function destinationEid() external view returns (uint32) {
        return _getStorage().destinationEid;
    }

    /// @notice Accept native currency used to fund LayerZero relay fees
    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @inheritdoc OAppSenderUpgradeable
    function oAppVersion()
        public
        pure
        override(OAppSenderUpgradeable)
        returns (uint64 senderVersion, uint64 receiverVersion)
    {
        return (1, 0);
    }

    /**
     * @dev Pay the LayerZero native fee from the contract's own balance instead of
     *      requiring `msg.value`. This is what lets {poke} be permissionless and
     *      non-payable: the protocol funds the relay (see {receive}/{withdraw}) and
     *      any third party can trigger a send without supplying ETH.
     * @param _nativeFee The native fee required by the endpoint
     * @return nativeFee The amount forwarded to the endpoint (drawn from this balance)
     */
    function _payNative(uint256 _nativeFee) internal view override returns (uint256 nativeFee) {
        if (address(this).balance < _nativeFee) revert InsufficientBalance();
        return _nativeFee;
    }

    /**
     * @dev Returns true if `current` deviates from `last` by at least `bps` basis points.
     *      Always true when there is no prior price (`last == 0`), forcing the first send.
     */
    function _deviated(uint256 last, uint256 current, uint32 bps) private pure returns (bool) {
        if (last == 0) return true;
        uint256 diff = current > last ? current - last : last - current;
        return diff * BPS_DENOMINATOR >= uint256(bps) * last;
    }

    function _getStorage() private pure returns (PriceRelayStorage storage $) {
        assembly {
            $.slot := PriceRelayStorageLocation
        }
    }
}
