// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPriceProvider} from "../interfaces/IPriceProvider.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {UpgradeableProxy} from "../utils/UpgradeableProxy.sol";

/**
 * @title PriceProvider
 * @author ether.fi
 * @notice Contract for retrieving token prices from various oracles
 * @dev Implements upgradeable proxy pattern and supports multiple price oracle types including Chainlink
 */
contract PriceProvider is UpgradeableProxy {
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
        /// @notice Whether the price is denominated in ETH (needs conversion to USD)
        bool isBaseTokenEth;
        /// @notice Whether the token is a stablecoin (special price handling)
        bool isStableToken;
    }

    /// @custom:storage-location erc7201:etherfi.storage.PriceProvider
    /**
     * @dev Storage struct for PriceProvider (follows ERC-7201 naming convention)
     */
    struct PriceProviderStorage {
        /// @notice Mapping of token addresses to their price oracle configurations
        mapping(address token => Config tokenConfig) tokenConfig;
    }

    /**
     * @notice Storage location for PriceProvider (ERC-7201 compliant)
     * @dev keccak256(abi.encode(uint256(keccak256("etherfi.storage.PriceProvider")) - 1)) & ~bytes32(uint256(0xff))
     */
    bytes32 private constant PriceProviderStorageLocation = 0x41562816b7fe3348550ae5f01054abee62ae4ec684cc33be93b5202283b5ba00;

    /**
     * @notice Role identifier for administrative privileges over the price provider
     */
    bytes32 public constant PRICE_PROVIDER_ADMIN_ROLE = keccak256("PRICE_PROVIDER_ADMIN_ROLE");
    
    /**
     * @notice Special address used to request ETH/USD price
     * @dev This is not a real token address but a marker for the ETH/USD price request
     */
    address public constant ETH_USD_ORACLE_SELECTOR = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    /**
     * @notice Special address used to request WETH/USD price
     * @dev Similar to ETH_USD_ORACLE_SELECTOR but for wrapped ETH
     */
    address public constant WETH_USD_ORACLE_SELECTOR = 0x5300000000000000000000000000000000000004;
    
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
     * @notice Thrown when trying to get a price for a token with no configured oracle
     */
    error TokenOracleNotSet();
    
    /**
     * @notice Thrown when the price oracle call fails
     */
    error PriceOracleFailed();
    
    /**
     * @notice Thrown when a price oracle returns an invalid price (zero or negative)
     */
    error InvalidPrice();
    
    /**
     * @notice Thrown when the price data from an oracle is older than allowed
     */
    error OraclePriceTooOld();
    
    /**
     * @notice Thrown when arrays of tokens and configs have different lengths
     */
    error ArrayLengthMismatch();
    
    /**
     * @notice Thrown when a stablecoin price is calculated as zero
     */
    error StablePriceCannotBeZero();

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

    /**
     * @dev Internal function to access the contract's storage
     * @return $ Storage pointer to the PriceProviderStorage struct
     */
    function _getPriceProviderStorage() internal pure returns (PriceProviderStorage storage $) {
        assembly {
            $.slot := PriceProviderStorageLocation
        }
    }

    /**
     * @notice Returns the oracle configuration for a given token
     * @param token Address of the token
     * @return Configuration struct for the token's price oracle
     */
    function tokenConfig(address token) public view returns (Config memory) {
        return _getPriceProviderStorage().tokenConfig[token];
    }

    /**
     * @notice Updates the price oracle configurations for multiple tokens
     * @dev Only callable by addresses with PRICE_PROVIDER_ADMIN_ROLE
     * @param _tokens Array of token addresses to configure
     * @param _configs Array of configurations corresponding to each token
     * @custom:throws ArrayLengthMismatch If arrays have different lengths
     */
    function setTokenConfig(address[] calldata _tokens, Config[] calldata _configs) external onlyRole(PRICE_PROVIDER_ADMIN_ROLE) {
        _setTokenConfig(_tokens, _configs);
    }

    /**
     * @notice Gets the normalized USD price for a token with standard decimal precision
     * @dev Handles special cases for ETH/WETH and tokens priced in ETH
     * @param token Address of the token to get the price for
     * @return Price in USD with DECIMALS decimal places
     * @custom:throws TokenOracleNotSet If the token has no configured oracle
     * @custom:throws PriceOracleFailed If the oracle call fails
     * @custom:throws InvalidPrice If the oracle returns an invalid price
     * @custom:throws OraclePriceTooOld If the oracle data is stale
     * @custom:throws StablePriceCannotBeZero If a stablecoin price resolves to zero
     */
    function price(address token) external view returns (uint256) {
        if (token == ETH_USD_ORACLE_SELECTOR || token == WETH_USD_ORACLE_SELECTOR) {
            (uint256 ethUsdPrice, uint8 ethPriceDecimals) = _getEthUsdPrice();
            return ethUsdPrice.mulDiv(10 ** decimals(), 10 ** ethPriceDecimals, Math.Rounding.Floor);
        }

        (uint256 tokenPrice, bool isBaseEth, uint8 priceDecimals) = _getPrice(token);

        if (isBaseEth) {
            (uint256 ethUsdPrice, uint8 ethPriceDecimals) = _getEthUsdPrice();
            return tokenPrice.mulDiv(ethUsdPrice * 10 ** decimals(), 10 ** (ethPriceDecimals + priceDecimals), Math.Rounding.Floor);
        }

        return tokenPrice.mulDiv(10 ** decimals(), 10 ** priceDecimals, Math.Rounding.Floor);
    }

    /**
     * @notice Internal function to get the ETH/USD price
     * @dev Uses the configured ETH/USD oracle
     * @return Price of ETH in USD and the decimal precision of that price
     */
    function _getEthUsdPrice() internal view returns (uint256, uint8) {
        (uint256 tokenPrice, , uint8 priceDecimals) = _getPrice(ETH_USD_ORACLE_SELECTOR);
        return (tokenPrice, priceDecimals);
    }

    /**
     * @notice Returns the decimal precision used for prices in this contract
     * @return The number of decimal places (6)
     */
    function decimals() public pure returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Internal function to get the raw price for a token from its oracle
     * @dev Handles different oracle types and return formats
     * @param token Address of the token to get the price for
     * @return The raw price, whether it's denominated in ETH, and its decimal precision
     * @custom:throws TokenOracleNotSet If the token has no configured oracle
     * @custom:throws PriceOracleFailed If the oracle call fails
     * @custom:throws InvalidPrice If the oracle returns an invalid price
     * @custom:throws OraclePriceTooOld If the oracle data is stale
     * @custom:throws StablePriceCannotBeZero If a stablecoin price resolves to zero
     */
    function _getPrice(address token) internal view returns (uint256, bool, uint8) {
        Config memory config = _getPriceProviderStorage().tokenConfig[token];
        if (config.oracle == address(0)) revert TokenOracleNotSet();
        uint256 tokenPrice;

        if (config.isChainlinkType) {
            (, int256 priceInt256, , uint256 updatedAt, ) = IAggregatorV3(config.oracle).latestRoundData();
            if (block.timestamp > updatedAt + config.maxStaleness) revert OraclePriceTooOld();
            if (priceInt256 <= 0) revert InvalidPrice();
            tokenPrice = uint256(priceInt256);
            if (config.isStableToken) return (_getStablePrice(tokenPrice, config.oraclePriceDecimals), false, decimals());
            return (tokenPrice, config.isBaseTokenEth, config.oraclePriceDecimals);
        }

        (bool success, bytes memory data) = address(config.oracle).staticcall(config.priceFunctionCalldata);
        if (!success) revert PriceOracleFailed();

        if (config.dataType == ReturnType.Int256) {
            int256 priceInt256 = abi.decode(data, (int256));
            if (priceInt256 <= 0) revert InvalidPrice();
            tokenPrice = uint256(priceInt256);
        } else tokenPrice = abi.decode(data, (uint256));

        if (config.isStableToken) return (_getStablePrice(tokenPrice, config.oraclePriceDecimals), false, decimals());
        return (tokenPrice, config.isBaseTokenEth, config.oraclePriceDecimals);
    }

    /**
     * @notice Special handling for stablecoin prices
     * @dev Returns the standard stable price if the deviation is within bounds
     * @param _price Raw price from the oracle
     * @param oracleDecimals Decimal precision of the oracle's price output
     * @return Normalized stablecoin price
     * @custom:throws StablePriceCannotBeZero If the normalized price resolves to zero
     */
    function _getStablePrice(uint256 _price, uint8 oracleDecimals) internal pure returns (uint256) {    
        _price = _price.mulDiv(10 ** decimals(), 10 ** oracleDecimals);  
        if (_price == 0) revert StablePriceCannotBeZero();

        if (
            uint256(_price) > STABLE_PRICE - MAX_STABLE_DEVIATION &&
            uint256(_price) < STABLE_PRICE + MAX_STABLE_DEVIATION
        ) return STABLE_PRICE;
        else return _price;
    }

    /**
     * @notice Internal function to set token price configurations
     * @dev Updates storage and emits an event
     * @param _tokens Array of token addresses to configure
     * @param _configs Array of configurations corresponding to each token
     * @custom:throws ArrayLengthMismatch If arrays have different lengths
     */
    function _setTokenConfig(address[] calldata _tokens, Config[] calldata _configs) internal {
        uint256 len = _tokens.length;
        if(len != _configs.length) revert ArrayLengthMismatch();

        PriceProviderStorage storage $ = _getPriceProviderStorage();

        for (uint256 i = 0; i < len; ) {
            $.tokenConfig[_tokens[i]] = _configs[i];
            unchecked {
                ++i;
            }
        }

        emit TokenConfigSet(_tokens, _configs);
    }
}