using PriceProvider as priceProvider;

methods {
  function PriceProvider._getPrice(address token) internal returns (uint256, bool, bool, uint8) => cvlGetPrice(token);
  function PriceProvider.ETH_USD_ORACLE_SELECTOR() external returns (address) envfree;
  function PriceProvider.WETH_USD_ORACLE_SELECTOR() external returns (address) envfree;
  function PriceProvider.WBTC_USD_ORACLE_SELECTOR() external returns (address) envfree;
  function PriceProvider.decimals() external returns (uint8) envfree;
}

ghost uint256 ETH_price;
ghost uint256 WETH_price;
ghost uint256 OTHER_price;
ghost uint256 WBTC_price;
ghost uint256 LBTC_price;

ghost address LBTC_SELECTOR;

function cvlGetPrice(address token) returns (uint256, bool, bool, uint8) {
   if (token == priceProvider.ETH_USD_ORACLE_SELECTOR())
     return (ETH_price, false, false, priceProvider.decimals());
   else if (token == priceProvider.WETH_USD_ORACLE_SELECTOR())
     return (WETH_price, true, false, priceProvider.decimals());
   else if (token == priceProvider.WBTC_USD_ORACLE_SELECTOR())
     return (WBTC_price, false, false, priceProvider.decimals());
   else if (token == LBTC_SELECTOR)
     return (LBTC_price, false, true, priceProvider.decimals());
   else
     return (OTHER_price, false, false, priceProvider.decimals());
}

