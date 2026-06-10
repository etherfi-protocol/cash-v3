// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OAppCoreUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppCoreUpgradeable.sol";
import { OAppReceiverUpgradeable, Origin } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";

import { IOracleSink } from "../interfaces/IOracleSink.sol";
import { UpgradeableProxy } from "../utils/UpgradeableProxy.sol";

/**
 * @title OracleSink
 * @author ether.fi
 * @notice Destination-chain LayerZero receiver. Stores the latest relayed
 *         per-token USD price (6 decimals) and exposes it to the OP-side
 *         {PriceProvider} in two ways:
 *           1. Directly (no adapter) via {price}, read through PriceProvider's
 *              calldata branch. Freshness is enforced here against the
 *              relay-delivery timestamp using a per-token {maxStaleness}.
 *           2. Through a per-token Chainlink-shaped adapter over
 *              {latestRoundData}, read via PriceProvider's `isChainlinkType` branch.
 * @dev Because the relay only ships a normalised 6-decimal USD price (no source
 *      timestamp), the relay-delivery time recorded on this chain is the single
 *      freshness signal: if the relay stops delivering, {price} ages out and
 *      reverts. This is what lets even no-timestamp source oracles (e.g. a
 *      rate-provider `getRate()`) be consumed as fresh feeds on L2.
 */
contract OracleSink is IOracleSink, UpgradeableProxy, OAppReceiverUpgradeable {
    /// @custom:storage-location erc7201:etherfi.storage.OracleSink
    struct OracleSinkStorage {
        /// @notice Latest stored price per token
        mapping(address token => PricePoint) latest;
        /// @notice Max age (seconds) of a relayed price before {price} reverts (0 = disabled)
        mapping(address token => uint64) maxStaleness;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.OracleSink")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OracleSinkStorageLocation = 0x3e8ab8ffffa6cdbcb3cadbd9bce96c661061ed9516d20cf2ac88617c984e9200;

    /// @notice Matches {PriceProvider}.DECIMALS — kept here for the
    ///         Chainlink-shaped `decimals()` accessor.
    uint8 public constant DECIMALS = 6;

    /// @notice Role required to configure per-token staleness windows
    bytes32 public constant ORACLE_SINK_ADMIN_ROLE = keccak256("ORACLE_SINK_ADMIN_ROLE");

    /// @notice Thrown when constructor or initializer receives a zero address
    error InvalidAddress();

    /**
     * @dev Constructor fixes the LZ endpoint for this sink (one per chain).
     * @param _lzEndpoint LayerZero endpoint on the destination chain
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint) OAppCoreUpgradeable(_lzEndpoint) {
        if (_lzEndpoint == address(0)) revert InvalidAddress();
        _disableInitializers();
    }

    /**
     * @notice Initializer
     * @param _roleRegistry RoleRegistry contract
     * @param _delegate LayerZero delegate / OApp owner (e.g. protocol multisig)
     */
    function initialize(address _roleRegistry, address _delegate) external initializer {
        if (_roleRegistry == address(0) || _delegate == address(0)) revert InvalidAddress();
        __UpgradeableProxy_init(_roleRegistry);
        __Ownable_init(_delegate);
        __OAppReceiver_init(_delegate);
    }

    /// @inheritdoc IOracleSink
    function getPrice(address token) external view returns (uint256, uint64) {
        PricePoint memory p = _getStorage().latest[token];
        if (p.updatedAt == 0) revert PriceNotSet();
        return (p.price, p.updatedAt);
    }

    /// @inheritdoc IOracleSink
    function price(address token) external view returns (uint256) {
        OracleSinkStorage storage $ = _getStorage();
        PricePoint memory p = $.latest[token];
        if (p.updatedAt == 0) revert PriceNotSet();

        uint64 maxStaleness_ = $.maxStaleness[token];
        if (maxStaleness_ != 0 && block.timestamp > uint256(p.updatedAt) + maxStaleness_) revert PriceStale();

        return p.price;
    }

    /// @inheritdoc IOracleSink
    function setMaxStaleness(address token, uint64 maxStaleness_) external onlyRole(ORACLE_SINK_ADMIN_ROLE) {
        if (token == address(0)) revert InvalidToken();
        _getStorage().maxStaleness[token] = maxStaleness_;
        emit MaxStalenessSet(token, maxStaleness_);
    }

    /// @inheritdoc IOracleSink
    function maxStaleness(address token) external view returns (uint64) {
        return _getStorage().maxStaleness[token];
    }

    /// @inheritdoc IOracleSink
    function latestRoundData(address token)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        PricePoint memory p = _getStorage().latest[token];
        if (p.updatedAt == 0) revert PriceNotSet();
        return (0, int256(p.price), p.updatedAt, p.updatedAt, 0);
    }

    /// @inheritdoc IOracleSink
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    /**
     * @dev LayerZero callback. Decodes the relay payload and stores the
     *      per-token updates. The peer/origin authentication ("only the mainnet
     *      {PriceRelay} can write here") is already enforced upstream in
     *      {OAppReceiverUpgradeable.lzReceive} via the `OnlyPeer` check, so this
     *      function trusts `_message` once invoked.
     *
     *      Payload schema (must match {PriceRelay.poke}):
     *      `abi.encode(address[] tokens, uint256[] prices, uint64 srcTimestamp)`.
     *      `updatedAt` is stamped with the destination-chain `block.timestamp`
     *      (the time the price became readable here) so the OP-side
     *      {PriceProvider} staleness check measures local arrival, not source time.
     * @param _message Encoded relay payload
     */
    function _lzReceive(Origin calldata, bytes32, bytes calldata _message, address, bytes calldata)
        internal
        virtual
        override
    {
        (address[] memory tokens, uint256[] memory prices, ) = abi.decode(_message, (address[], uint256[], uint64));

        OracleSinkStorage storage $ = _getStorage();
        uint64 nowTs = uint64(block.timestamp);
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len;) {
            $.latest[tokens[i]] = PricePoint(prices[i], nowTs);
            emit PriceUpdated(tokens[i], prices[i], nowTs);
            unchecked {
                ++i;
            }
        }
    }

    function _getStorage() private pure returns (OracleSinkStorage storage $) {
        assembly {
            $.slot := OracleSinkStorageLocation
        }
    }
}
