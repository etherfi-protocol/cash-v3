// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceProvider} from "../interfaces/IPriceProvider.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {UpgradeableProxy} from "../utils/UpgradeableProxy.sol";

/**
 * @title PriceProviderV2
 * @author ether.fi
 * @notice Contract for retrieving token prices from various oracles with modular base asset support
 * @dev Unlike V1 which used individual boolean flags (isBaseTokenEth, isBaseTokenBtc etc)
 *      for each base asset, V2 uses a generic `baseAsset` address field. This allows adding new base
 *      assets purely through configuration without contract changes.
 *
 *      To add a new base asset:
 *        1. Configure an oracle for the base asset's USD price using any address as the token key and baseAsset = address(0).
 *        2. For tokens priced in that base asset, set their config's baseAsset field to the address used in step 1.
 *
 *      Base assets must be USD-denominated (baseAsset = address(0)). Chaining base assets is not supported.
 */
contract PriceProviderV2 is UpgradeableProxy {
    using Math for uint256;

    /**
     * @notice Enumeration of return data types from price oracles
     * @dev Used to correctly decode price data from non-standard oracles
     */
    enum ReturnType {
        Int256,
        Uint256
    }

    /**
     * @notice Configuration for a token's price oracle
     * @dev Stores all the parameters needed to fetch and normalize a token's price
     */
    struct Config {
        /// @notice Address of the price oracle contract
        address oracle;
        /// @notice Function call data for non-standard oracles
        bytes priceFunctionCalldata;
        /// @notice Whether the oracle follows Chainlink's interface
        bool isChainlinkType;
        /// @notice Decimal precision of the oracle's price output
        uint8 oraclePriceDecimals;
        /// @notice Maximum allowed age of price data in seconds
        uint24 maxStaleness;
        /// @notice Return type of the oracle data (int256 or uint256)
        ReturnType dataType;
        /// @notice Whether the token is a stablecoin (special price handling)
        bool isStableToken;
        /// @notice Base asset for price conversion. address(0) = USD-denominated.
        /// If set, the oracle returns price in terms of this base asset, which is then converted to USD.
        /// The base asset itself must have a config with baseAsset = address(0).
        address baseAsset;
    }

    /// @custom:storage-location erc7201:etherfi.storage.PriceProviderV2
    struct PriceProviderV2Storage {
        /// @notice Mapping of token addresses to their price oracle configurations
        mapping(address token => Config tokenConfig) tokenConfig;
    }

    /**
     * @notice Storage location for PriceProviderV2 (ERC-7201 compliant)
     * @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.PriceProviderV2")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant PriceProviderV2StorageLocation = 0x8f2acf35259c059f6119c1863bba219d395429d54dbfcce655d5bf4a17660700;

    /**
     * @notice Role identifier for administrative privileges over the price provider
     */
    bytes32 public constant PRICE_PROVIDER_ADMIN_ROLE = keccak256("PRICE_PROVIDER_ADMIN_ROLE");

    /**
     * @notice Decimal precision used for all price outputs from this contract
     */
    uint8 public constant DECIMALS = 6;

    /**
     * @notice Standard price value for stablecoins (1 USD with DECIMALS precision)
     */
    uint256 public constant STABLE_PRICE = 10 ** DECIMALS;

    /**
     * @notice Maximum allowed deviation from STABLE_PRICE for stablecoins (1%)
     */
    uint256 public constant MAX_STABLE_DEVIATION = STABLE_PRICE / 100; // 1%

    /**
     * @notice Emitted when token price configurations are updated
     * @param tokens Array of token addresses that were configured
     * @param configs Array of configuration objects corresponding to each token
     */
    event TokenConfigSet(address[] tokens, Config[] configs);

    /**
     * @notice Emitted when a token's price configuration is removed
     * @param token Address of the token whose config was removed
     */
    event TokenConfigRemoved(address token);

    /**
     * @notice Thrown when trying to get a price for a token with no configured oracle
     */
    error TokenOracleNotSet();
    /**
     * @notice Thrown when the price oracle call fails
     */
    error PriceOracleFailed();
    /**
     * @notice Thrown when the oracle price is invalid
     */
    error InvalidPrice();
    /**
     * @notice Thrown when the oracle price is too old
     */
    error OraclePriceTooOld();
    /**
     * @notice Thrown when the arrays have different lengths
     */
    error ArrayLengthMismatch();
    /**
     * @notice Thrown when a stablecoin price is calculated as zero
     */
    error StablePriceCannotBeZero();
    /**
     * @notice Thrown when a base asset has baseAsset != address(0) (chaining not supported)
     */
    error InvalidBaseAsset();
    /**
     * @notice Thrown when a token's baseAsset references an oracle that is not yet configured
     */
    error BaseAssetOracleNotSet();
    /**
     * @notice Thrown when a Chainlink oracle config has maxStaleness set to zero
     */
    error MaxStalenessCannotBeZero();
    /**
     * @notice Thrown when trying to remove a token config that is not set
     */
    error TokenConfigNotSet();

    /**
     * @notice Constructor that disables initializers
     * @dev Cannot be called again after deployment (UUPS pattern)
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract with role registry and token configurations
     * @dev Can only be called once due to initializer modifier
     * @param _roleRegistry Address of the role registry contract
     * @param _tokens Array of token addresses to configure
     * @param _configs Array of configurations corresponding to each token
     */
    function initialize(address _roleRegistry, address[] calldata _tokens, Config[] calldata _configs) external initializer {
        __UpgradeableProxy_init(_roleRegistry);
        _setTokenConfig(_tokens, _configs);
    }

    function _getPriceProviderV2Storage() internal pure returns (PriceProviderV2Storage storage $) {
        assembly {
            $.slot := PriceProviderV2StorageLocation
        }
    }

    /**
     * @notice Returns the oracle configuration for a given token
     * @param token Address of the token
     * @return Configuration struct for the token's price oracle
     */
    function tokenConfig(address token) public view returns (Config memory) {
        return _getPriceProviderV2Storage().tokenConfig[token];
    }

    /**
     * @notice Updates the price oracle configurations for multiple tokens
     * @dev Only callable by addresses with PRICE_PROVIDER_ADMIN_ROLE
     * @param _tokens Array of token addresses to configure
     * @param _configs Array of configurations corresponding to each token
     */
    function setTokenConfig(address[] calldata _tokens, Config[] calldata _configs) external onlyRole(PRICE_PROVIDER_ADMIN_ROLE) {
        _setTokenConfig(_tokens, _configs);
    }

    /**
     * @notice Removes the price oracle configuration for a token
     * @dev Only callable by addresses with PRICE_PROVIDER_ADMIN_ROLE
     * @param _token Address of the token to remove the config for
     */
    function removeTokenConfig(address _token) external onlyRole(PRICE_PROVIDER_ADMIN_ROLE) {
        PriceProviderV2Storage storage $ = _getPriceProviderV2Storage();
        if ($.tokenConfig[_token].oracle == address(0)) revert TokenConfigNotSet();
        delete $.tokenConfig[_token];
        emit TokenConfigRemoved(_token);
    }

    /**
     * @notice Gets the normalized USD price for a token with standard decimal precision
     * @dev If the token has a base asset configured, the raw oracle price is multiplied
     *      by the base asset's USD price. Base assets must be USD-denominated.
     * @param token Address of the token to get the price for
     * @return Price in USD with DECIMALS decimal places
     */
    function price(address token) external view returns (uint256) {
        Config memory config = _getPriceProviderV2Storage().tokenConfig[token];
        if (config.oracle == address(0)) revert TokenOracleNotSet();

        uint256 rawPrice = _fetchRawPrice(config);

        if (config.isStableToken) {
            return _getStablePrice(rawPrice, config.oraclePriceDecimals);
        }

        if (config.baseAsset != address(0)) {
            Config memory baseConfig = _getPriceProviderV2Storage().tokenConfig[config.baseAsset];
            if (baseConfig.oracle == address(0)) revert TokenOracleNotSet();
            if (baseConfig.baseAsset != address(0)) revert InvalidBaseAsset();

            uint256 basePrice = _fetchRawPrice(baseConfig);
            uint8 basePriceDecimals = baseConfig.oraclePriceDecimals;

            if (baseConfig.isStableToken) {
                basePrice = _getStablePrice(basePrice, basePriceDecimals);
                basePriceDecimals = decimals();
            }

            return rawPrice.mulDiv(
                basePrice * 10 ** decimals(),
                10 ** (basePriceDecimals + config.oraclePriceDecimals),
                Math.Rounding.Floor
            );
        }

        return rawPrice.mulDiv(10 ** decimals(), 10 ** config.oraclePriceDecimals, Math.Rounding.Floor);
    }

    /**
     * @notice Returns the decimal precision used for prices
     * @return The number of decimal places (6)
     */
    function decimals() public pure returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Fetches the raw price from an oracle based on the config
     * @dev Handles Chainlink and custom oracle types with staleness/validity checks
     * @param config The oracle configuration for the token
     * @return The raw price value from the oracle (not normalized to DECIMALS)
     */
    function _fetchRawPrice(Config memory config) internal view returns (uint256) {
        if (config.isChainlinkType) {
            (, int256 priceInt256, , uint256 updatedAt, ) = IAggregatorV3(config.oracle).latestRoundData();
            if (block.timestamp > updatedAt + config.maxStaleness) revert OraclePriceTooOld();
            if (priceInt256 <= 0) revert InvalidPrice();
            return uint256(priceInt256);
        }

        (bool success, bytes memory data) = address(config.oracle).staticcall(config.priceFunctionCalldata);
        if (!success) revert PriceOracleFailed();

        if (config.dataType == ReturnType.Int256) {
            int256 priceInt256 = abi.decode(data, (int256));
            if (priceInt256 <= 0) revert InvalidPrice();
            return uint256(priceInt256);
        }

        uint256 decodedPrice = abi.decode(data, (uint256));
        if (decodedPrice == 0) revert InvalidPrice();

        return decodedPrice;
    }

    /**
     * @notice Special handling for stablecoin prices
     * @dev Returns the standard stable price if the deviation is within bounds
     * @param _price Raw price from the oracle
     * @param oracleDecimals Decimal precision of the oracle's price output
     * @return Normalized stablecoin price
     */
    function _getStablePrice(uint256 _price, uint8 oracleDecimals) internal pure returns (uint256) {
        _price = _price.mulDiv(10 ** decimals(), 10 ** oracleDecimals);
        if (_price == 0) revert StablePriceCannotBeZero();

        if (_price > STABLE_PRICE - MAX_STABLE_DEVIATION && _price < STABLE_PRICE + MAX_STABLE_DEVIATION) {
            return STABLE_PRICE;
        }
        return _price;
    }

    /**
     * @notice Internal function to set token price configurations
     * @param _tokens Array of token addresses to configure
     * @param _configs Array of configurations corresponding to each token
     */
    function _setTokenConfig(address[] calldata _tokens, Config[] calldata _configs) internal {
        uint256 len = _tokens.length;
        if (len != _configs.length) revert ArrayLengthMismatch();

        PriceProviderV2Storage storage $ = _getPriceProviderV2Storage();

        for (uint256 i = 0; i < len; ) {
            if (_configs[i].isChainlinkType && _configs[i].maxStaleness == 0) revert MaxStalenessCannotBeZero();

            if (_configs[i].baseAsset != address(0)) {
                if ($.tokenConfig[_configs[i].baseAsset].oracle == address(0)) revert BaseAssetOracleNotSet();
                if ($.tokenConfig[_configs[i].baseAsset].baseAsset != address(0)) revert InvalidBaseAsset();
            }
            $.tokenConfig[_tokens[i]] = _configs[i];
            unchecked {
                ++i;
            }
        }

        emit TokenConfigSet(_tokens, _configs);
    }
}
