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
 *         per-token USD price (6 decimals) and exposes it via a Chainlink
 *         `latestRoundData(token)` shape so the existing OP-side
 *         {PriceProvider} can consume it with no contract changes —
 *         configure each token with `isChainlinkType = true` and
 *         `oracle = address(thisOracleSink)` (or a per-token Chainlink-shaped
 *         adapter view; see {IOracleSink} for the calldata-shape variant).
 * @dev The relay payload format is intentionally unfixed in this skeleton —
 *      {`_lzReceive`} decodes are left as TODOs. The companion {PriceRelay}
 *      MUST encode/decode against the same schema once chosen.
 */
contract OracleSink is IOracleSink, UpgradeableProxy, OAppReceiverUpgradeable {
    /// @custom:storage-location erc7201:etherfi.storage.OracleSink
    struct OracleSinkStorage {
        /// @notice Latest stored price per token
        mapping(address token => PricePoint) latest;
    }

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.OracleSink")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OracleSinkStorageLocation = 0x3e8ab8ffffa6cdbcb3cadbd9bce96c661061ed9516d20cf2ac88617c984e9200;

    /// @notice Matches {PriceProvider}.DECIMALS — kept here for the
    ///         Chainlink-shaped `decimals()` accessor.
    uint8 public constant DECIMALS = 6;

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
    function getPrice(address token) external view returns (uint256 price, uint64 updatedAt) {
        PricePoint memory p = _getStorage().latest[token];
        if (p.updatedAt == 0) revert PriceNotSet();
        return (p.price, p.updatedAt);
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
     *      per-token updates. Skeleton: payload encoding is a TODO.
     * @param _origin LZ origin metadata (peer + nonce)
     * @param _guid Globally-unique message id
     * @param _message Encoded relay payload (schema TBD with {PriceRelay})
     */
    function _lzReceive(Origin calldata _origin, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        internal
        virtual
        override
    {
        _origin;
        _guid;

        // TODO: decode payload (tokens[], prices[], srcTimestamp) and
        // write into `_getStorage().latest[token] = PricePoint(price, uint64(block.timestamp));`
        // Example placeholder:
        // (address[] memory tokens, uint256[] memory prices, ) = abi.decode(_message, (address[], uint256[], uint64));
        // for (uint256 i = 0; i < tokens.length; ++i) {
        //     _getStorage().latest[tokens[i]] = PricePoint(prices[i], uint64(block.timestamp));
        //     emit PriceUpdated(tokens[i], prices[i], uint64(block.timestamp));
        // }
        _message;
    }

    function _getStorage() private pure returns (OracleSinkStorage storage $) {
        assembly {
            $.slot := OracleSinkStorageLocation
        }
    }
}
