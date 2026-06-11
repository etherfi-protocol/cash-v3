// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EnumerableSetLib } from "solady/utils/EnumerableSetLib.sol";

import { OAppCoreUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import { MessagingFee, OAppSenderUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppSenderUpgradeable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import { IPriceProvider } from "../interfaces/IPriceProvider.sol";
import { IPriceRelay } from "../interfaces/IPriceRelay.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title PriceRelay
 * @author ether.fi
 * @notice Mainnet-side LayerZero sender. Reads the existing {PriceProvider}
 *         (already normalised to 6-decimal USD) and pushes the price of every
 *         subscribed token to an {OracleSink} on the destination chain in a
 *         single message.
 * @dev Caller-pays: {poke} is payable and the LayerZero fee is taken from
 *      `msg.value` (any excess is refunded to the caller). There is therefore no
 *      protocol balance to drain, so no on-chain rate-limiting/gating is needed:
 *      the off-chain keeper decides when to relay (e.g. every N min / on X%
 *      deviation) and simply pays for the call. {subscribe} is just an allowlist
 *      of which tokens get relayed.
 */
contract PriceRelay is IPriceRelay, UpgradeableProxy, OAppSenderUpgradeable {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;
    using OptionsBuilder for bytes;

    /// @custom:storage-location erc7201:etherfi.storage.PriceRelay
    /// @dev Slot order is preserved from the original layout (priceProvider,
    ///      destinationEid, <3rd slot>, subscribed) so this is an upgrade-safe
    ///      change; the 3rd slot's `bytes lzOptions` was replaced by a `uint128`
    ///      gas limit (an unset `bytes` reads as 0, same as an unset uint128).
    struct PriceRelayStorage {
        /// @notice Mainnet PriceProvider singleton (source of truth)
        IPriceProvider priceProvider;
        /// @notice Destination LayerZero endpoint ID (the OracleSink chain)
        uint32 destinationEid;
        /// @notice Executor gas limit for OracleSink.lzReceive on the destination chain
        uint128 lzReceiveGasLimit;
        /// @notice Tokens currently allow-listed for relay
        EnumerableSetLib.AddressSet subscribed;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.PriceRelay")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PriceRelayStorageLocation = 0xa5f763f5f22412144904c62075e838be98e71aa6e5b4ffe579f23d0f3e43c800;

    /// @notice Role required to subscribe / unsubscribe tokens and configure the relay
    bytes32 public constant PRICE_RELAY_ADMIN_ROLE = keccak256("PRICE_RELAY_ADMIN_ROLE");

    /// @notice Thrown when constructor or initializer receives a zero address
    error InvalidAddress();

    /**
     * @dev Constructor fixes the LZ endpoint for the relay (one per chain).
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
    function subscribe(address token) external onlyRole(PRICE_RELAY_ADMIN_ROLE) {
        if (token == address(0)) revert InvalidInput();
        _getStorage().subscribed.add(token);
        emit TokenSubscribed(token);
    }

    /// @inheritdoc IPriceRelay
    function unsubscribe(address token) external onlyRole(PRICE_RELAY_ADMIN_ROLE) {
        if (!_getStorage().subscribed.remove(token)) revert TokenNotSubscribed();
        emit TokenUnsubscribed(token);
    }

    /// @inheritdoc IPriceRelay
    function setLzReceiveGasLimit(uint128 gasLimit) external onlyRole(PRICE_RELAY_ADMIN_ROLE) {
        _getStorage().lzReceiveGasLimit = gasLimit;
        emit LzReceiveGasLimitSet(gasLimit);
    }

    /// @inheritdoc IPriceRelay
    function poke() external payable {
        PriceRelayStorage storage $ = _getStorage();
        uint32 dstEid = $.destinationEid;
        if (dstEid == 0) revert DestinationNotSet();

        (address[] memory tokens, uint256[] memory prices) = _readAll($);
        bytes memory payload = abi.encode(tokens, prices, uint64(block.timestamp));
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption($.lzReceiveGasLimit, 0);

        MessagingFee memory fee = _quote(dstEid, payload, options, false);
        if (msg.value < fee.nativeFee) revert InsufficientFee();
        _lzSend(dstEid, payload, options, MessagingFee(msg.value, 0), msg.sender);

        emit PricesRelayed(dstEid, tokens, prices);
    }

    /// @inheritdoc IPriceRelay
    function quote() external view returns (uint256 nativeFee) {
        PriceRelayStorage storage $ = _getStorage();
        if ($.destinationEid == 0) revert DestinationNotSet();
        (address[] memory tokens, uint256[] memory prices) = _readAll($);
        bytes memory payload = abi.encode(tokens, prices, uint64(0));
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption($.lzReceiveGasLimit, 0);
        MessagingFee memory fee = _quote($.destinationEid, payload, options, false);
        return fee.nativeFee;
    }

    /// @inheritdoc IPriceRelay
    function subscribedTokens() external view returns (address[] memory) {
        return _getStorage().subscribed.values();
    }

    /// @inheritdoc IPriceRelay
    function isSubscribed(address token) external view returns (bool) {
        return _getStorage().subscribed.contains(token);
    }

    /// @inheritdoc IPriceRelay
    function lzReceiveGasLimit() external view returns (uint128) {
        return _getStorage().lzReceiveGasLimit;
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

    /// @dev Reads the current price of every subscribed token. Reverts if none are subscribed.
    function _readAll(PriceRelayStorage storage $)
        private
        view
        returns (address[] memory tokens, uint256[] memory prices)
    {
        tokens = $.subscribed.values();
        uint256 len = tokens.length;
        if (len == 0) revert InvalidInput();
        IPriceProvider priceProvider = $.priceProvider;
        prices = new uint256[](len);
        for (uint256 i = 0; i < len;) {
            prices[i] = priceProvider.price(tokens[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _getStorage() private pure returns (PriceRelayStorage storage $) {
        assembly {
            $.slot := PriceRelayStorageLocation
        }
    }
}
