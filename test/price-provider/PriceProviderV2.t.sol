// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {PriceProviderV2} from "../../src/oracle/PriceProviderV2.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {ILayerZeroTeller, AccountantWithRateProviders} from "../../src/interfaces/ILayerZeroTeller.sol";
import {IWeETH} from "../../src/interfaces/IWeETH.sol";
import {UUPSProxy} from "../../src/UUPSProxy.sol";
import {RoleRegistry} from "../../src/role-registry/RoleRegistry.sol";
import {UpgradeableProxy} from "../../src/utils/UpgradeableProxy.sol";

contract PriceProviderV2Test is Test {
    PriceProviderV2 priceProvider;
    RoleRegistry public roleRegistry;
    address dataProvider = makeAddr("dataProvider");
    address owner = makeAddr("owner");

    // Token addresses (mainnet)
    address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address btc = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address eth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address matic = 0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0;
    address eurc = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;

    // Oracle addresses (mainnet Chainlink)
    address weETHOracle = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address btcUsdOracle = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address ethUsdOracle = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address maticUsdOracle = 0x7bAC85A8a13A4BcD8abb3eB7d6b4d632c5a57676;

    // Liquid tokens
    address liquidBtc = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    ILayerZeroTeller public liquidBtcTeller = ILayerZeroTeller(0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353);

    // Configs
    PriceProviderV2.Config weETHConfig;
    PriceProviderV2.Config btcConfig;
    PriceProviderV2.Config ethConfig;
    PriceProviderV2.Config maticConfig;
    PriceProviderV2.Config liquidBtcConfig;

    function setUp() public {
        string memory mainnet = vm.envString("MAINNET_RPC");
        if (bytes(mainnet).length == 0) mainnet = "https://rpc.ankr.com/eth";

        vm.createSelectFork(mainnet);

        vm.startPrank(owner);

        address roleRegistryImpl = address(new RoleRegistry(address(dataProvider)));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        // ETH/USD - direct USD oracle, no base asset
        ethConfig = PriceProviderV2.Config({
            oracle: ethUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(ethUsdOracle).decimals(),
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });

        // BTC/USD - direct USD oracle, no base asset
        btcConfig = PriceProviderV2.Config({
            oracle: btcUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(btcUsdOracle).decimals(),
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });

        // weETH - exchange rate oracle, priced in ETH (baseAsset = eth)
        weETHConfig = PriceProviderV2.Config({
            oracle: weETHOracle,
            priceFunctionCalldata: abi.encodeWithSelector(IWeETH.getEETHByWeETH.selector, 1000000000000000000),
            isChainlinkType: false,
            oraclePriceDecimals: 18,
            maxStaleness: 0,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: eth
        });

        // MATIC/USD - direct USD oracle
        maticConfig = PriceProviderV2.Config({
            oracle: maticUsdOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(maticUsdOracle).decimals(),
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });

        // liquidBtc - custom oracle, priced in BTC (baseAsset = btc)
        AccountantWithRateProviders liquidBtcAccountant = liquidBtcTeller.accountant();
        liquidBtcConfig = PriceProviderV2.Config({
            oracle: address(liquidBtcAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: liquidBtcAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: btc
        });

        // Deploy with initial tokens: eth, btc, weETH, liquidBtc
        address[] memory initialTokens = new address[](4);
        initialTokens[0] = eth;
        initialTokens[1] = btc;
        initialTokens[2] = weETH;
        initialTokens[3] = liquidBtc;

        PriceProviderV2.Config[] memory initialConfigs = new PriceProviderV2.Config[](4);
        initialConfigs[0] = ethConfig;
        initialConfigs[1] = btcConfig;
        initialConfigs[2] = weETHConfig;
        initialConfigs[3] = liquidBtcConfig;

        priceProvider = PriceProviderV2(address(new UUPSProxy(
            address(new PriceProviderV2()),
            abi.encodeWithSelector(
                PriceProviderV2.initialize.selector,
                address(roleRegistry),
                initialTokens,
                initialConfigs
            )
        )));

        roleRegistry.grantRole(priceProvider.PRICE_PROVIDER_ADMIN_ROLE(), owner);

        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Direct USD-denominated prices
    // ---------------------------------------------------------------

    function test_price_directUsd_eth() public view {
        (, int256 ethAns, , , ) = IAggregatorV3(ethUsdOracle).latestRoundData();
        uint256 oracleDecimals = IAggregatorV3(ethUsdOracle).decimals();
        uint256 expected = (uint256(ethAns) * 10 ** priceProvider.decimals()) / 10 ** oracleDecimals;
        assertEq(priceProvider.price(eth), expected);
    }

    function test_price_directUsd_btc() public view {
        (, int256 btcAns, , , ) = IAggregatorV3(btcUsdOracle).latestRoundData();
        uint256 oracleDecimals = IAggregatorV3(btcUsdOracle).decimals();
        uint256 expected = (uint256(btcAns) * 10 ** priceProvider.decimals()) / 10 ** oracleDecimals;
        assertEq(priceProvider.price(btc), expected);
    }

    function test_price_directUsd_matic() public {
        _addToken(matic, maticConfig);

        (, int256 maticAns, , , ) = IAggregatorV3(maticUsdOracle).latestRoundData();
        uint256 oracleDecimals = IAggregatorV3(maticUsdOracle).decimals();
        uint256 expected = (uint256(maticAns) * 10 ** priceProvider.decimals()) / 10 ** oracleDecimals;
        assertEq(priceProvider.price(matic), expected);
    }

    // ---------------------------------------------------------------
    // Base asset conversion (ETH base)
    // ---------------------------------------------------------------

    function test_price_baseAssetEth_weETH() public view {
        uint256 weETHRate = IWeETH(weETH).getEETHByWeETH(1 ether);
        (, int256 ethAns, , , ) = IAggregatorV3(ethUsdOracle).latestRoundData();
        uint256 ethOracleDecimals = IAggregatorV3(ethUsdOracle).decimals();

        uint256 expected = (weETHRate * uint256(ethAns) * 10 ** priceProvider.decimals()) / 10 ** (18 + ethOracleDecimals);
        assertEq(priceProvider.price(weETH), expected);
    }

    // ---------------------------------------------------------------
    // Base asset conversion (BTC base)
    // ---------------------------------------------------------------

    function test_price_baseAssetBtc_liquidBtc() public view {
        uint256 liquidBtcRate = liquidBtcTeller.accountant().getRate();
        uint256 liquidBtcDecimals = liquidBtcTeller.accountant().decimals();
        (, int256 btcAns, , , ) = IAggregatorV3(btcUsdOracle).latestRoundData();
        uint256 btcOracleDecimals = IAggregatorV3(btcUsdOracle).decimals();

        uint256 expected = (liquidBtcRate * uint256(btcAns) * 10 ** priceProvider.decimals()) / 10 ** (liquidBtcDecimals + btcOracleDecimals);
        assertEq(priceProvider.price(liquidBtc), expected);
    }

    // ---------------------------------------------------------------
    // Base asset conversion (EUR base) - adding a new base asset without contract changes
    // ---------------------------------------------------------------

    function test_price_baseAssetEur_token() public {
        // Step 1: Configure EUR/USD as a base asset oracle (mock: 1.08 USD per EUR)
        address eurBaseOracle = address(new MockChainlinkOracle(1_08000000, 8));
        PriceProviderV2.Config memory eurBaseConfig = PriceProviderV2.Config({
            oracle: eurBaseOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        _addToken(eurc, eurBaseConfig);

        // Step 2: Configure a EUR-denominated token (mock: 1.05 EUR)
        address eurToken = makeAddr("eurToken");
        address eurTokenOracle = address(new MockChainlinkOracle(1_05000000, 8));
        PriceProviderV2.Config memory eurTokenConfig = PriceProviderV2.Config({
            oracle: eurTokenOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: eurc
        });
        _addToken(eurToken, eurTokenConfig);

        // eurToken price = 1.05 * 1.08 = 1.134 USD -> 1134000 at 6 decimals
        // Exact: (105000000 * 108000000 * 10^6) / 10^(8+8) = 1134000
        assertEq(priceProvider.price(eurToken), 1134000);
    }

    function test_price_directBaseAsset_eurUsd() public {
        // Configure EUR/USD directly (mock: 1.08 USD per EUR)
        address eurBaseOracle = address(new MockChainlinkOracle(1_08000000, 8));
        PriceProviderV2.Config memory eurBaseConfig = PriceProviderV2.Config({
            oracle: eurBaseOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        _addToken(eurc, eurBaseConfig);

        // 1.08 USD -> 1080000 at 6 decimals
        assertEq(priceProvider.price(eurc), 1080000);
    }

    // ---------------------------------------------------------------
    // Stablecoin handling
    // ---------------------------------------------------------------

    function test_price_stablecoin_withinDeviation_returnsStablePrice() public {
        address usdc = makeAddr("usdc");
        // 0.999 USD -> within 1% of $1, should return STABLE_PRICE
        address mockOracle = address(new MockChainlinkOracle(99900000, 8));

        PriceProviderV2.Config memory usdcConfig = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: true,
            baseAsset: address(0)
        });
        _addToken(usdc, usdcConfig);

        assertEq(priceProvider.price(usdc), priceProvider.STABLE_PRICE());
    }

    function test_price_stablecoin_outsideDeviation_returnsActualPrice() public {
        address usdc = makeAddr("usdc");
        // 0.95 USD -> outside 1% deviation, should return actual price
        address mockOracle = address(new MockChainlinkOracle(95000000, 8));

        PriceProviderV2.Config memory usdcConfig = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: true,
            baseAsset: address(0)
        });
        _addToken(usdc, usdcConfig);

        // 0.95 * 10^6 / 10^8 * 10^6 = 950000
        assertEq(priceProvider.price(usdc), 950000);
    }

    function test_price_stableBaseAsset_clampAppliedToConversion() public {
        // Base asset is a stablecoin (e.g., USDC at 0.999 — within 1% → clamped to 1.0)
        address stableBase = makeAddr("stableBase");
        address stableBaseOracle = address(new MockChainlinkOracle(99900000, 8)); // 0.999 USD

        _addToken(stableBase, PriceProviderV2.Config({
            oracle: stableBaseOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: true,
            baseAsset: address(0)
        }));

        // Token priced in the stable base at 2.5x
        address token = makeAddr("stableBasedToken");
        address tokenOracle = address(new MockChainlinkOracle(2_50000000, 8));

        _addToken(token, PriceProviderV2.Config({
            oracle: tokenOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: stableBase
        }));

        // Direct price of stableBase: clamped to STABLE_PRICE = 1000000
        assertEq(priceProvider.price(stableBase), priceProvider.STABLE_PRICE());

        // Token price should use clamped base (1.0), not raw (0.999)
        // 2.5 * 1.0 = 2.5 USD -> 2500000
        // _getStablePrice returns 1000000 (6 decimals), so:
        // rawPrice(250000000) * 1000000 * 10^6 / 10^(6 + 8) = 2500000
        assertEq(priceProvider.price(token), 2500000);
    }

    // ---------------------------------------------------------------
    // Error cases
    // ---------------------------------------------------------------

    function test_price_reverts_tokenOracleNotSet() public {
        address unknown = makeAddr("unknown");
        vm.expectRevert(PriceProviderV2.TokenOracleNotSet.selector);
        priceProvider.price(unknown);
    }

    function test_setTokenConfig_reverts_baseAssetOracleNotSet() public {
        address fakeBase = makeAddr("fakeBase");
        address token = makeAddr("token");
        address mockOracle = address(new MockChainlinkOracle(100000000, 8));

        PriceProviderV2.Config memory tokenConfig = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: fakeBase
        });

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
        configs[0] = tokenConfig;

        vm.prank(owner);
        vm.expectRevert(PriceProviderV2.BaseAssetOracleNotSet.selector);
        priceProvider.setTokenConfig(tokens, configs);
    }

    function test_price_reverts_invalidBaseAsset_chained() public {
        // Set up: base1 -> base2 -> USD (chaining not allowed)
        address base2 = makeAddr("base2");
        address base1 = makeAddr("base1");
        address token = makeAddr("token");

        address mockOracle1 = address(new MockChainlinkOracle(100000000, 8));
        address mockOracle2 = address(new MockChainlinkOracle(200000000, 8));
        address mockOracle3 = address(new MockChainlinkOracle(300000000, 8));

        // base2 is USD-denominated (valid base)
        _addToken(base2, PriceProviderV2.Config({
            oracle: mockOracle1,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        }));

        // base1 has baseAsset = base2 (chained base)
        _addToken(base1, PriceProviderV2.Config({
            oracle: mockOracle2,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: base2
        }));

        // token has baseAsset = base1 (which itself has a base asset -> should revert)
        _addToken(token, PriceProviderV2.Config({
            oracle: mockOracle3,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: base1
        }));

        vm.expectRevert(PriceProviderV2.InvalidBaseAsset.selector);
        priceProvider.price(token);
    }

    function test_price_reverts_oraclePriceTooOld() public {
        address token = makeAddr("token");
        address mockOracle = address(new MockChainlinkOracle(100000000, 8));

        PriceProviderV2.Config memory config = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 hours,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        _addToken(token, config);

        // Warp forward past staleness
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(PriceProviderV2.OraclePriceTooOld.selector);
        priceProvider.price(token);
    }

    function test_price_reverts_invalidPrice_negative() public {
        address token = makeAddr("token");
        address mockOracle = address(new MockChainlinkOracle(-1, 8));

        PriceProviderV2.Config memory config = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        _addToken(token, config);

        vm.expectRevert(PriceProviderV2.InvalidPrice.selector);
        priceProvider.price(token);
    }

    function test_price_reverts_invalidPrice_zero() public {
        address token = makeAddr("token");
        address mockOracle = address(new MockChainlinkOracle(0, 8));

        PriceProviderV2.Config memory config = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        _addToken(token, config);

        vm.expectRevert(PriceProviderV2.InvalidPrice.selector);
        priceProvider.price(token);
    }

    function test_price_reverts_oracleFailed_customOracle() public {
        address token = makeAddr("token");
        address mockOracle = address(new MockFailingOracle());

        PriceProviderV2.Config memory config = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: abi.encodeWithSelector(MockFailingOracle.getPrice.selector),
            isChainlinkType: false,
            oraclePriceDecimals: 18,
            maxStaleness: 0,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: address(0)
        });
        _addToken(token, config);

        vm.expectRevert(PriceProviderV2.PriceOracleFailed.selector);
        priceProvider.price(token);
    }

    function test_price_reverts_stablePriceCannotBeZero() public {
        address token = makeAddr("token");
        // Price so small it rounds to zero with decimal conversion: 0.000000001 with 18 decimals -> 0 at 6 decimals
        address mockOracle = address(new MockChainlinkOracle(1, 18));

        PriceProviderV2.Config memory config = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 18,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: true,
            baseAsset: address(0)
        });
        _addToken(token, config);

        vm.expectRevert(PriceProviderV2.StablePriceCannotBeZero.selector);
        priceProvider.price(token);
    }

    // ---------------------------------------------------------------
    // setTokenConfig
    // ---------------------------------------------------------------

    function test_setTokenConfig_succeeds_emitsEvent() public {
        address[] memory tokens = new address[](1);
        tokens[0] = matic;

        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
        configs[0] = maticConfig;

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PriceProviderV2.TokenConfigSet(tokens, configs);
        priceProvider.setTokenConfig(tokens, configs);

        PriceProviderV2.Config memory stored = priceProvider.tokenConfig(matic);
        assertEq(stored.oracle, maticUsdOracle);
        assertEq(stored.baseAsset, address(0));
    }

    function test_setTokenConfig_reverts_unauthorized() public {
        address[] memory tokens = new address[](1);
        tokens[0] = matic;

        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
        configs[0] = maticConfig;

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        priceProvider.setTokenConfig(tokens, configs);
    }

    function test_setTokenConfig_reverts_arrayLengthMismatch() public {
        address[] memory tokens = new address[](2);
        tokens[0] = matic;
        tokens[1] = makeAddr("other");

        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
        configs[0] = maticConfig;

        vm.prank(owner);
        vm.expectRevert(PriceProviderV2.ArrayLengthMismatch.selector);
        priceProvider.setTokenConfig(tokens, configs);
    }

    function test_setTokenConfig_reverts_baseAssetNotConfigured_wrongBatchOrder() public {
        // If dependent token appears BEFORE base asset in the same batch, it should revert
        address newBase = makeAddr("newBase");
        address dependent = makeAddr("dependent");
        address baseOracle = address(new MockChainlinkOracle(100000000, 8));
        address depOracle = address(new MockChainlinkOracle(200000000, 8));

        address[] memory tokens = new address[](2);
        tokens[0] = dependent; // dependent first
        tokens[1] = newBase;   // base second

        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](2);
        configs[0] = PriceProviderV2.Config({
            oracle: depOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: newBase
        });
        configs[1] = PriceProviderV2.Config({
            oracle: baseOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });

        vm.prank(owner);
        vm.expectRevert(PriceProviderV2.BaseAssetOracleNotSet.selector);
        priceProvider.setTokenConfig(tokens, configs);
    }

    function test_setTokenConfig_succeeds_baseAssetConfigured_correctBatchOrder() public {
        // If base asset appears BEFORE dependent token in the same batch, it should succeed
        address newBase = makeAddr("newBase");
        address dependent = makeAddr("dependent");
        address baseOracle = address(new MockChainlinkOracle(100000000, 8));
        address depOracle = address(new MockChainlinkOracle(200000000, 8));

        address[] memory tokens = new address[](2);
        tokens[0] = newBase;   // base first
        tokens[1] = dependent; // dependent second

        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](2);
        configs[0] = PriceProviderV2.Config({
            oracle: baseOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        configs[1] = PriceProviderV2.Config({
            oracle: depOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: newBase
        });

        vm.prank(owner);
        priceProvider.setTokenConfig(tokens, configs);

        // Verify: dependent = 2.0 * 1.0 = 2.0 -> 2000000
        assertEq(priceProvider.price(dependent), 2000000);
    }

    function test_setTokenConfig_overwritesExistingConfig() public {
        // Change ETH oracle to a mock
        address mockOracle = address(new MockChainlinkOracle(250000000000, 8)); // $2500
        PriceProviderV2.Config memory newEthConfig = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        _addToken(eth, newEthConfig);

        assertEq(priceProvider.price(eth), 2500_000000);
    }

    // ---------------------------------------------------------------
    // Custom (non-Chainlink) oracles
    // ---------------------------------------------------------------

    function test_price_customOracle_uint256Return() public {
        address token = makeAddr("customToken");
        address mockOracle = address(new MockUint256Oracle(2_000000000000000000)); // 2.0 in 18 decimals

        PriceProviderV2.Config memory config = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: abi.encodeWithSelector(MockUint256Oracle.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: 18,
            maxStaleness: 0,
            dataType: PriceProviderV2.ReturnType.Uint256,
            isStableToken: false,
            baseAsset: eth
        });
        _addToken(token, config);

        // Expected: 2.0 * ethPrice
        (, int256 ethAns, , , ) = IAggregatorV3(ethUsdOracle).latestRoundData();
        uint256 ethOracleDecimals = IAggregatorV3(ethUsdOracle).decimals();
        uint256 expected = (2_000000000000000000 * uint256(ethAns) * 10 ** priceProvider.decimals()) / 10 ** (ethOracleDecimals + 18);
        assertEq(priceProvider.price(token), expected);
    }

    function test_price_customOracle_int256Return_negative_reverts() public {
        address token = makeAddr("customToken");
        address mockOracle = address(new MockInt256Oracle(-5));

        PriceProviderV2.Config memory config = PriceProviderV2.Config({
            oracle: mockOracle,
            priceFunctionCalldata: abi.encodeWithSelector(MockInt256Oracle.getPrice.selector),
            isChainlinkType: false,
            oraclePriceDecimals: 8,
            maxStaleness: 0,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        _addToken(token, config);

        vm.expectRevert(PriceProviderV2.InvalidPrice.selector);
        priceProvider.price(token);
    }

    // ---------------------------------------------------------------
    // Multiple base assets configured simultaneously
    // ---------------------------------------------------------------

    function test_price_multipleBaseAssets_coexist() public {
        // Configure EUR/USD base asset + EUR-denominated token alongside existing ETH/BTC base assets
        address eurBaseOracle = address(new MockChainlinkOracle(1_08000000, 8)); // 1.08 USD/EUR
        address eurToken = makeAddr("eurToken");
        address eurTokenOracle = address(new MockChainlinkOracle(1_10000000, 8)); // 1.10 EUR

        address[] memory tokens = new address[](2);
        tokens[0] = eurc;
        tokens[1] = eurToken;

        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](2);
        configs[0] = PriceProviderV2.Config({
            oracle: eurBaseOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: address(0)
        });
        configs[1] = PriceProviderV2.Config({
            oracle: eurTokenOracle,
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 8,
            maxStaleness: 1 days,
            dataType: PriceProviderV2.ReturnType.Int256,
            isStableToken: false,
            baseAsset: eurc
        });

        vm.prank(owner);
        priceProvider.setTokenConfig(tokens, configs);

        // Verify EUR/USD direct: 1.08 -> 1080000
        assertEq(priceProvider.price(eurc), 1080000);

        // Verify EUR-denominated token: 1.10 * 1.08 = 1.188 -> 1188000
        assertEq(priceProvider.price(eurToken), 1188000);

        // Verify BTC-based token still works
        uint256 liquidBtcRate = liquidBtcTeller.accountant().getRate();
        uint256 liquidBtcDec = liquidBtcTeller.accountant().decimals();
        (, int256 btcAns, , , ) = IAggregatorV3(btcUsdOracle).latestRoundData();
        uint256 btcDec = IAggregatorV3(btcUsdOracle).decimals();
        uint256 expectedLiquidBtc = (liquidBtcRate * uint256(btcAns) * 10 ** priceProvider.decimals()) / 10 ** (liquidBtcDec + btcDec);
        assertEq(priceProvider.price(liquidBtc), expectedLiquidBtc);

        // Verify ETH-based token still works
        uint256 weETHRate = IWeETH(weETH).getEETHByWeETH(1 ether);
        (, int256 ethAns, , , ) = IAggregatorV3(ethUsdOracle).latestRoundData();
        uint256 ethDec = IAggregatorV3(ethUsdOracle).decimals();
        uint256 expectedWeETH = (weETHRate * uint256(ethAns) * 10 ** priceProvider.decimals()) / 10 ** (18 + ethDec);
        assertEq(priceProvider.price(weETH), expectedWeETH);
    }

    // ---------------------------------------------------------------
    // tokenConfig view
    // ---------------------------------------------------------------

    function test_tokenConfig_returnsCorrectConfig() public view {
        PriceProviderV2.Config memory config = priceProvider.tokenConfig(eth);
        assertEq(config.oracle, ethUsdOracle);
        assertTrue(config.isChainlinkType);
        assertEq(config.baseAsset, address(0));
        assertFalse(config.isStableToken);
    }

    function test_tokenConfig_unconfiguredToken_returnsZeroOracle() public {
        address unconfigured = makeAddr("unconfigured");
        PriceProviderV2.Config memory config = priceProvider.tokenConfig(unconfigured);
        assertEq(config.oracle, address(0));
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    function _addToken(address token, PriceProviderV2.Config memory config) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;

        PriceProviderV2.Config[] memory configs = new PriceProviderV2.Config[](1);
        configs[0] = config;

        vm.prank(owner);
        priceProvider.setTokenConfig(tokens, configs);
    }
}

// ---------------------------------------------------------------
// Mock oracles
// ---------------------------------------------------------------

contract MockChainlinkOracle {
    int256 private _price;
    uint8 private _decimals;
    uint256 private _updatedAt;

    constructor(int256 price_, uint8 decimals_) {
        _price = price_;
        _decimals = decimals_;
        _updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _price, 0, _updatedAt, 0);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

contract MockUint256Oracle {
    uint256 private _rate;

    constructor(uint256 rate_) {
        _rate = rate_;
    }

    function getRate() external view returns (uint256) {
        return _rate;
    }
}

contract MockInt256Oracle {
    int256 private _price;

    constructor(int256 price_) {
        _price = price_;
    }

    function getPrice() external view returns (int256) {
        return _price;
    }
}

contract MockFailingOracle {
    function getPrice() external pure {
        revert("oracle failure");
    }
}
