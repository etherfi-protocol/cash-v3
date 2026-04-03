// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { BinSponsor } from "../src/interfaces/ICashModule.sol";
import { SettlementDispatcherV2 } from "../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { LiquidUSDLiquifierModule } from "../src/modules/etherfi/LiquidUSDLiquifier.sol";
import { EtherFiLiquidModule } from "../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { StargateModule } from "../src/modules/stargate/StargateModule.sol";
import { FraxModule } from "../src/modules/frax/FraxModule.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { IAggregatorV3, PriceProvider } from "../src/oracle/PriceProvider.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { ILayerZeroTeller, AccountantWithRateProviders } from "../src/interfaces/ILayerZeroTeller.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { Utils } from "./utils/Utils.sol";

contract DeployOptimismDevModules is Utils {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // --- CREATE3 salts (impl + proxy for UUPS, just impl for direct deploys) ---
    bytes32 public constant SALT_SETTLEMENT_PIX_IMPL          = keccak256("DeployOptimismDevModules.SettlementPixImpl");
    bytes32 public constant SALT_SETTLEMENT_PIX_PROXY         = keccak256("DeployOptimismDevModules.SettlementPixProxy");
    bytes32 public constant SALT_SETTLEMENT_CARD_ORDER_IMPL   = keccak256("DeployOptimismDevModules.SettlementCardOrderImpl");
    bytes32 public constant SALT_SETTLEMENT_CARD_ORDER_PROXY  = keccak256("DeployOptimismDevModules.SettlementCardOrderProxy");
    bytes32 public constant SALT_LIQUIFIER_IMPL               = keccak256("DeployOptimismDevModules.LiquidUSDLiquifierImpl");
    bytes32 public constant SALT_LIQUIFIER_PROXY              = keccak256("DeployOptimismDevModules.LiquidUSDLiquifierProxy");
    bytes32 public constant SALT_LIQUID_MODULE                = keccak256("DeployOptimismDevModules.EtherFiLiquidModule");
    bytes32 public constant SALT_LIQUID_MODULE_REFERRER       = keccak256("DeployOptimismDevModules.EtherFiLiquidModuleWithReferrer");
    bytes32 public constant SALT_STARGATE_MODULE              = keccak256("DeployOptimismDevModules.StargateModule");
    bytes32 public constant SALT_FRAX_MODULE                  = keccak256("DeployOptimismDevModules.FraxModule");

    // OP chain addresses
    address constant weth = 0x4200000000000000000000000000000000000006;
    address constant usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant weETH = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address constant usdt = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;

    // EtherFi Liquid vault assets (same as Scroll)
    address constant liquidEth = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address constant liquidEthTeller = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    address constant liquidUsd = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant liquidUsdTeller = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    address constant liquidBtc = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address constant liquidBtcTeller = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353;
    address constant ebtc = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address constant ebtcTeller = 0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268;

    // sETHFI (same as Scroll)
    address constant sethfi = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address constant sethfiTeller = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;
    address constant sETHFIBoringQueue = 0xF03352da1536F31172A7F7cB092D4717DeDDd3CB;

    // Stargate
    address constant stargateUsdcPool = 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0;

    // Frax
    address constant frxUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant fraxCustodian = 0x8C81eda18b8F1cF5AdB4f2dcDb010D0B707fd940;
    address constant fraxRemoteHop = 0x31D982ebd82Ad900358984bd049207A4c2468640;
    address constant frxUSDPriceOracle = 0x8BF42811876e1B692d0E70F61b80e1fbc68Ef1bf;

    address deployer;

    struct Deployed {
        address dataProvider;
        address debtManager;
        address roleRegistry;
        address priceProvider;
        address cashModule;
        address liquidModule;
        address liquidModuleReferrer;
        address stargateModule;
        address fraxModule;
    }

    // --- CREATE3 deploy helper (idempotent — skips if already deployed) ---
    function deployCreate3(bytes memory creationCode, bytes32 salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH)))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");

        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }

    function run() public {
        require(block.chainid == 10, "This script must be run on Optimism (chain ID 10)");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        Deployed memory d;
        d.dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));
        d.debtManager = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager"));
        d.roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));
        d.priceProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider"));
        d.cashModule = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule"));

        _deploySettlementDispatchers(d);
        _deployModules(d);
        _configureModules(d);
        _configureOracles(d.priceProvider);
        _configureDebtManager(d.debtManager);

        vm.stopBroadcast();
    }

    function _deploySettlementDispatchers(Deployed memory d) internal {
        console.log("Deploying SettlementDispatcherPix...");
        address pixImplAddr = deployCreate3(
            abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.PIX, d.dataProvider)),
            SALT_SETTLEMENT_PIX_IMPL
        );
        address[] memory emptyTokens = new address[](0);
        SettlementDispatcherV2.DestinationData[] memory emptyDests = new SettlementDispatcherV2.DestinationData[](0);
        address pixProxyAddr = deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(pixImplAddr, abi.encodeWithSelector(SettlementDispatcherV2.initialize.selector, d.roleRegistry, emptyTokens, emptyDests))
            ),
            SALT_SETTLEMENT_PIX_PROXY
        );
        console.log("  SettlementDispatcherPix proxy:", pixProxyAddr);

        console.log("Deploying SettlementDispatcherCardOrder...");
        address cardOrderImplAddr = deployCreate3(
            abi.encodePacked(type(SettlementDispatcherV2).creationCode, abi.encode(BinSponsor.CardOrder, d.dataProvider)),
            SALT_SETTLEMENT_CARD_ORDER_IMPL
        );
        address cardOrderProxyAddr = deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(cardOrderImplAddr, abi.encodeWithSelector(SettlementDispatcherV2.initialize.selector, d.roleRegistry, emptyTokens, emptyDests))
            ),
            SALT_SETTLEMENT_CARD_ORDER_PROXY
        );
        console.log("  SettlementDispatcherCardOrder proxy:", cardOrderProxyAddr);

        console.log("Deploying LiquidUSDLiquifierModule...");
        address liquifierImplAddr = deployCreate3(
            abi.encodePacked(type(LiquidUSDLiquifierModule).creationCode, abi.encode(d.debtManager, d.dataProvider)),
            SALT_LIQUIFIER_IMPL
        );
        address liquifierProxyAddr = deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(liquifierImplAddr, abi.encodeWithSelector(LiquidUSDLiquifierModule.initialize.selector, d.roleRegistry))
            ),
            SALT_LIQUIFIER_PROXY
        );
        console.log("  LiquidUSDLiquifierModule proxy:", liquifierProxyAddr);
    }

    function _deployModules(Deployed memory d) internal {
        console.log("Deploying EtherFiLiquidModule...");
        address[] memory liquidAssets = new address[](4);
        liquidAssets[0] = liquidEth;
        liquidAssets[1] = liquidBtc;
        liquidAssets[2] = liquidUsd;
        liquidAssets[3] = ebtc;

        address[] memory liquidTellers = new address[](4);
        liquidTellers[0] = liquidEthTeller;
        liquidTellers[1] = liquidBtcTeller;
        liquidTellers[2] = liquidUsdTeller;
        liquidTellers[3] = ebtcTeller;

        d.liquidModule = deployCreate3(
            abi.encodePacked(type(EtherFiLiquidModule).creationCode, abi.encode(liquidAssets, liquidTellers, d.dataProvider, weth)),
            SALT_LIQUID_MODULE
        );
        console.log("  EtherFiLiquidModule:", d.liquidModule);

        console.log("Deploying EtherFiLiquidModuleWithReferrer...");
        address[] memory referrerAssets = new address[](1);
        referrerAssets[0] = sethfi;

        address[] memory referrerTellers = new address[](1);
        referrerTellers[0] = sethfiTeller;

        d.liquidModuleReferrer = deployCreate3(
            abi.encodePacked(type(EtherFiLiquidModuleWithReferrer).creationCode, abi.encode(referrerAssets, referrerTellers, d.dataProvider, weth)),
            SALT_LIQUID_MODULE_REFERRER
        );

        bytes32 ETHERFI_LIQUID_MODULE_ADMIN = keccak256("ETHERFI_LIQUID_MODULE_ADMIN");
        RoleRegistry(d.roleRegistry).grantRole(ETHERFI_LIQUID_MODULE_ADMIN, deployer);
        EtherFiLiquidModuleWithReferrer(d.liquidModuleReferrer).setLiquidAssetWithdrawQueue(sethfi, sETHFIBoringQueue);
        console.log("  EtherFiLiquidModuleWithReferrer:", d.liquidModuleReferrer);

        console.log("Deploying StargateModule...");
        address[] memory stargateAssets = new address[](2);
        stargateAssets[0] = usdc;
        stargateAssets[1] = weETH;

        StargateModule.AssetConfig[] memory stargateConfigs = new StargateModule.AssetConfig[](2);
        stargateConfigs[0] = StargateModule.AssetConfig({isOFT: false, pool: stargateUsdcPool});
        stargateConfigs[1] = StargateModule.AssetConfig({isOFT: true, pool: weETH});

        d.stargateModule = deployCreate3(
            abi.encodePacked(type(StargateModule).creationCode, abi.encode(stargateAssets, stargateConfigs, d.dataProvider)),
            SALT_STARGATE_MODULE
        );
        console.log("  StargateModule:", d.stargateModule);

        console.log("Deploying FraxModule...");
        d.fraxModule = deployCreate3(
            abi.encodePacked(type(FraxModule).creationCode, abi.encode(d.dataProvider, frxUSD, fraxCustodian, fraxRemoteHop)),
            SALT_FRAX_MODULE
        );
        console.log("  FraxModule:", d.fraxModule);
    }

    function _configureModules(Deployed memory d) internal {
        console.log("Configuring modules...");

        address[] memory defaultModules = new address[](4);
        defaultModules[0] = d.liquidModule;
        defaultModules[1] = d.liquidModuleReferrer;
        defaultModules[2] = d.fraxModule;
        defaultModules[3] = d.stargateModule;

        bool[] memory shouldWhitelist = new bool[](4);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;
        shouldWhitelist[2] = true;
        shouldWhitelist[3] = true;

        EtherFiDataProvider(d.dataProvider).configureDefaultModules(defaultModules, shouldWhitelist);

        address[] memory withdrawableAssets = new address[](6);
        withdrawableAssets[0] = sethfi;
        withdrawableAssets[1] = frxUSD;
        withdrawableAssets[2] = liquidUsd;
        withdrawableAssets[3] = ebtc;
        withdrawableAssets[4] = liquidEth;
        withdrawableAssets[5] = liquidBtc;

        bool[] memory isWithdrawable = new bool[](6);
        isWithdrawable[0] = true;
        isWithdrawable[1] = true;
        isWithdrawable[2] = true;
        isWithdrawable[3] = true;
        isWithdrawable[4] = true;
        isWithdrawable[5] = true;

        ICashModule(d.cashModule).configureWithdrawAssets(withdrawableAssets, isWithdrawable);

        address[] memory withdrawModules = new address[](3);
        withdrawModules[0] = d.liquidModuleReferrer;
        withdrawModules[1] = d.fraxModule;
        withdrawModules[2] = d.stargateModule;

        bool[] memory canRequestWithdraw = new bool[](3);
        canRequestWithdraw[0] = true;
        canRequestWithdraw[1] = true;
        canRequestWithdraw[2] = true;

        ICashModule(d.cashModule).configureModulesCanRequestWithdraw(withdrawModules, canRequestWithdraw);
    }

    function _configureOracles(address priceProvider) internal {
        console.log("Configuring oracles...");

        AccountantWithRateProviders liquidEthAccountant = ILayerZeroTeller(liquidEthTeller).accountant();
        AccountantWithRateProviders liquidBtcAccountant = ILayerZeroTeller(liquidBtcTeller).accountant();
        AccountantWithRateProviders liquidUsdAccountant = ILayerZeroTeller(liquidUsdTeller).accountant();
        AccountantWithRateProviders ebtcAccountant = ILayerZeroTeller(ebtcTeller).accountant();

        address[] memory priceTokens = new address[](5);
        priceTokens[0] = frxUSD;
        priceTokens[1] = liquidEth;
        priceTokens[2] = liquidBtc;
        priceTokens[3] = liquidUsd;
        priceTokens[4] = ebtc;

        PriceProvider.Config[] memory priceConfigs = new PriceProvider.Config[](5);

        priceConfigs[0] = PriceProvider.Config({
            oracle: frxUSDPriceOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(frxUSDPriceOracle).decimals(),
            maxStaleness: 14 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: true,
            isBaseTokenBtc: false
        });

        priceConfigs[1] = PriceProvider.Config({
            oracle: address(liquidEthAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: liquidEthAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: true,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        priceConfigs[2] = PriceProvider.Config({
            oracle: address(liquidBtcAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: liquidBtcAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: true
        });

        priceConfigs[3] = PriceProvider.Config({
            oracle: address(liquidUsdAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: liquidUsdAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        priceConfigs[4] = PriceProvider.Config({
            oracle: address(ebtcAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: ebtcAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: true
        });

        PriceProvider(priceProvider).setTokenConfig(priceTokens, priceConfigs);
    }

    function _configureDebtManager(address debtManager) internal {
        console.log("Configuring DebtManager...");

        IDebtManager(debtManager).supportCollateralToken(frxUSD, IDebtManager.CollateralTokenConfig({
            ltv: 90e18, liquidationThreshold: 95e18, liquidationBonus: 1e18
        }));
        IDebtManager(debtManager).supportBorrowToken(frxUSD, 1, type(uint128).max);

        IDebtManager(debtManager).supportCollateralToken(liquidEth, IDebtManager.CollateralTokenConfig({
            ltv: 50e18, liquidationThreshold: 70e18, liquidationBonus: 5e18
        }));

        IDebtManager(debtManager).supportCollateralToken(liquidBtc, IDebtManager.CollateralTokenConfig({
            ltv: 50e18, liquidationThreshold: 70e18, liquidationBonus: 5e18
        }));

        IDebtManager(debtManager).supportCollateralToken(liquidUsd, IDebtManager.CollateralTokenConfig({
            ltv: 80e18, liquidationThreshold: 90e18, liquidationBonus: 2e18
        }));
        IDebtManager(debtManager).supportBorrowToken(liquidUsd, 1, type(uint128).max);

        IDebtManager(debtManager).supportCollateralToken(ebtc, IDebtManager.CollateralTokenConfig({
            ltv: 52e18, liquidationThreshold: 72e18, liquidationBonus: 5e18
        }));

        IDebtManager(debtManager).supportBorrowToken(usdt, 1, type(uint128).max);
    }
}
