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
 *      role-registry owner.
 *
 *      Subscription set, sending payload encoding, and quote semantics are
 *      stubbed here as TODOs — this file is the compiling skeleton.
 */
contract PriceRelay is IPriceRelay, UpgradeableProxy, OAppSenderUpgradeable {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    /// @custom:storage-location erc7201:etherfi.storage.PriceRelay
    struct PriceRelayStorage {
        /// @notice Mainnet PriceProvider singleton (source of truth)
        IPriceProvider priceProvider;
        /// @notice Destination LayerZero endpoint ID (the OracleSink chain)
        uint32 destinationEid;
        /// @notice Tokens currently subscribed for relay
        EnumerableSetLib.AddressSet subscribed;
        /// @notice Per-token subscription parameters
        mapping(address token => TokenSubscription) subscriptions;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.PriceRelay")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PriceRelayStorageLocation = 0xa5f763f5f22412144904c62075e838be98e71aa6e5b4ffe579f23d0f3e43c800;

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
        emit TokenUnsubscribed(token);
    }

    /// @inheritdoc IPriceRelay
    function poke(address[] calldata tokens, bytes calldata options) external payable whenNotPaused {
        if (tokens.length == 0) revert InvalidInput();
        PriceRelayStorage storage $ = _getStorage();
        if ($.destinationEid == 0) revert DestinationNotSet();

        uint256[] memory prices = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length;) {
            address token = tokens[i];
            if (!$.subscribed.contains(token)) revert TokenNotSubscribed();
            prices[i] = $.priceProvider.price(token);
            unchecked {
                ++i;
            }
        }

        // TODO: encode payload (e.g. abi.encode(tokens, prices, block.timestamp))
        // TODO: _lzSend($.destinationEid, payload, options, MessagingFee(msg.value, 0), msg.sender);
        options;

        emit PricesRelayed($.destinationEid, tokens, prices);
    }

    /// @inheritdoc IPriceRelay
    function quote(address[] calldata tokens, bytes calldata options)
        external
        view
        returns (uint256 nativeFee, uint256 lzTokenFee)
    {
        if (tokens.length == 0) revert InvalidInput();
        PriceRelayStorage storage $ = _getStorage();
        if ($.destinationEid == 0) revert DestinationNotSet();

        // TODO: build the same payload as `poke` and call `_quote`.
        // bytes memory payload = abi.encode(tokens, new uint256[](tokens.length), uint64(0));
        // MessagingFee memory fee = _quote($.destinationEid, payload, options, false);
        // return (fee.nativeFee, fee.lzTokenFee);
        tokens;
        options;
        return (0, 0);
    }

    /// @inheritdoc IPriceRelay
    function subscriptionOf(address token) external view returns (TokenSubscription memory) {
        return _getStorage().subscriptions[token];
    }

    /// @inheritdoc IPriceRelay
    function destinationEid() external view returns (uint32) {
        return _getStorage().destinationEid;
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

    function _getStorage() private pure returns (PriceRelayStorage storage $) {
        assembly {
            $.slot := PriceRelayStorageLocation
        }
    }
}
