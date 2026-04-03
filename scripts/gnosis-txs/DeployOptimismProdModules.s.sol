// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { LiquidUSDLiquifierModule } from "../../src/modules/etherfi/LiquidUSDLiquifier.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IAggregatorV3, PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { ILayerZeroTeller, AccountantWithRateProviders } from "../../src/interfaces/ILayerZeroTeller.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract DeployOptimismProdModules is GnosisHelpers, Utils, Test {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // --- CREATE3 salts ---
    bytes32 public constant SALT_LIQUID_MODULE            = keccak256("DeployOptimismProdModules.EtherFiLiquidModule");
    bytes32 public constant SALT_LIQUID_MODULE_REFERRER   = keccak256("DeployOptimismProdModules.EtherFiLiquidModuleWithReferrer");
    bytes32 public constant SALT_STARGATE_MODULE          = keccak256("DeployOptimismProdModules.StargateModule");
    bytes32 public constant SALT_FRAX_MODULE              = keccak256("DeployOptimismProdModules.FraxModule");
    bytes32 public constant SALT_LIQUIFIER_IMPL           = keccak256("DeployOptimismProdModules.LiquidUSDLiquifierImpl");
    bytes32 public constant SALT_LIQUIFIER_PROXY          = keccak256("DeployOptimismProdModules.LiquidUSDLiquifierProxy");

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

    // Boring queues (same as Scroll)
    address constant liquidEthBoringQueue = 0x0D2dF071207E18Ca8638b4f04E98c53155eC2cE0;
    address constant liquidBtcBoringQueue = 0x77A2fd42F8769d8063F2E75061FC200014E41Edf;
    address constant liquidUsdBoringQueue = 0x38FC1BA73b7ED289955a07d9F11A85b6E388064A;
    address constant ebtcBoringQueue = 0x686696A3e59eE16e8A8533d84B62cfA504827135;

    // Stargate
    address constant stargateUsdcPool = 0xcE8CcA271Ebc0533920C83d39F417ED6A0abB7D0;

    // Frax
    address constant frxUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant fraxCustodian = 0x8C81eda18b8F1cF5AdB4f2dcDb010D0B707fd940;
    address constant fraxRemoteHop = 0x31D982ebd82Ad900358984bd049207A4c2468640;
    address constant frxUSDPriceOracle = 0x8BF42811876e1B692d0E70F61b80e1fbc68Ef1bf;

    // Deployed addresses (filled during run)
    address liquidModule;
    address liquidModuleReferrer;
    address stargateModule;
    address fraxModule;
    address liquifierProxy;

    // Addresses from deployments.json
    address dataProvider;
    address debtManager;
    address roleRegistry;
    address priceProvider;
    address cashModule;

    // --- CREATE3 deploy helper (idempotent) ---
    function deployCreate3(bytes memory creationCode, bytes32 _salt) internal returns (address deployed) {
        deployed = CREATE3.predictDeterministicAddress(_salt, NICKS_FACTORY);

        if (deployed.code.length > 0) {
            console.log("  [SKIP] already deployed at", deployed);
            return deployed;
        }

        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, _salt, CREATE3.PROXY_INITCODE_HASH)))));

        bool ok;
        if (proxy.code.length == 0) {
            (ok,) = NICKS_FACTORY.call(abi.encodePacked(_salt, hex"67363d3d37363d34f03d5260086018f3"));
            require(ok, "CREATE3 proxy deploy failed");
        }

        (ok,) = proxy.call(creationCode);
        require(ok, "CREATE3 contract deploy failed");

        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }

    function run() public {
        require(block.chainid == 10, "This script must be run on Optimism (chain ID 10)");

        string memory deployments = readDeploymentFile();
        dataProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "EtherFiDataProvider"));
        debtManager = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "DebtManager"));
        roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));
        priceProvider = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "PriceProvider"));
        cashModule = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "CashModule"));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        // --- Deploy contracts via CREATE3 (deployer broadcast) ---
        vm.startBroadcast(deployerPrivateKey);

        _deployModules();
        _deployLiquifier();

        vm.stopBroadcast();

        // --- Build gnosis transaction bundle for config ---
        string memory chainId = vm.toString(block.chainid);
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        txs = _buildRoleGrantTxs(txs);
        txs = _buildModuleConfigTxs(txs);
        txs = _buildOracleConfigTxs(txs);
        txs = _buildDebtManagerConfigTxs(txs);

        vm.createDir("./output", true);
        string memory path = "./output/DeployOptimismProdModules.json";
        vm.writeFile(path, txs);

        // Simulate gnosis bundle
        executeGnosisTransactionBundle(path);

        // Post-simulation assertions
        _assertDeployment();
    }

    function _deployModules() internal {
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

        liquidModule = deployCreate3(
            abi.encodePacked(type(EtherFiLiquidModule).creationCode, abi.encode(liquidAssets, liquidTellers, dataProvider, weth)),
            SALT_LIQUID_MODULE
        );
        console.log("  EtherFiLiquidModule:", liquidModule);

        console.log("Deploying EtherFiLiquidModuleWithReferrer...");
        address[] memory referrerAssets = new address[](1);
        referrerAssets[0] = sethfi;
        address[] memory referrerTellers = new address[](1);
        referrerTellers[0] = sethfiTeller;

        liquidModuleReferrer = deployCreate3(
            abi.encodePacked(type(EtherFiLiquidModuleWithReferrer).creationCode, abi.encode(referrerAssets, referrerTellers, dataProvider, weth)),
            SALT_LIQUID_MODULE_REFERRER
        );
        console.log("  EtherFiLiquidModuleWithReferrer:", liquidModuleReferrer);

        console.log("Deploying StargateModule...");
        address[] memory stargateAssets = new address[](2);
        stargateAssets[0] = usdc;
        stargateAssets[1] = weETH;

        StargateModule.AssetConfig[] memory stargateConfigs = new StargateModule.AssetConfig[](2);
        stargateConfigs[0] = StargateModule.AssetConfig({isOFT: false, pool: stargateUsdcPool});
        stargateConfigs[1] = StargateModule.AssetConfig({isOFT: true, pool: weETH});

        stargateModule = deployCreate3(
            abi.encodePacked(type(StargateModule).creationCode, abi.encode(stargateAssets, stargateConfigs, dataProvider)),
            SALT_STARGATE_MODULE
        );
        console.log("  StargateModule:", stargateModule);

        console.log("Deploying FraxModule...");
        fraxModule = deployCreate3(
            abi.encodePacked(type(FraxModule).creationCode, abi.encode(dataProvider, frxUSD, fraxCustodian, fraxRemoteHop)),
            SALT_FRAX_MODULE
        );
        console.log("  FraxModule:", fraxModule);
    }

    function _deployLiquifier() internal {
        console.log("Deploying LiquidUSDLiquifierModule...");
        address liquifierImplAddr = deployCreate3(
            abi.encodePacked(type(LiquidUSDLiquifierModule).creationCode, abi.encode(debtManager, dataProvider)),
            SALT_LIQUIFIER_IMPL
        );
        liquifierProxy = deployCreate3(
            abi.encodePacked(
                type(UUPSProxy).creationCode,
                abi.encode(liquifierImplAddr, abi.encodeWithSelector(LiquidUSDLiquifierModule.initialize.selector, roleRegistry))
            ),
            SALT_LIQUIFIER_PROXY
        );
        console.log("  LiquidUSDLiquifierModule proxy:", liquifierProxy);
    }

    function _buildRoleGrantTxs(string memory txs) internal view returns (string memory) {
        bytes32 ETHERFI_LIQUID_MODULE_ADMIN = keccak256("ETHERFI_LIQUID_MODULE_ADMIN");
        bytes32 STARGATE_MODULE_ADMIN_ROLE = keccak256("STARGATE_MODULE_ADMIN_ROLE");

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(roleRegistry),
            iToHex(abi.encodeWithSelector(RoleRegistry.grantRole.selector, ETHERFI_LIQUID_MODULE_ADMIN, cashControllerSafe)),
            "0", false
        )));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(roleRegistry),
            iToHex(abi.encodeWithSelector(RoleRegistry.grantRole.selector, STARGATE_MODULE_ADMIN_ROLE, cashControllerSafe)),
            "0", false
        )));

        return txs;
    }

    function _buildModuleConfigTxs(string memory txs) internal view returns (string memory) {
        address[] memory defaultModules = new address[](4);
        defaultModules[0] = liquidModule;
        defaultModules[1] = liquidModuleReferrer;
        defaultModules[2] = fraxModule;
        defaultModules[3] = stargateModule;

        bool[] memory enable = new bool[](4);
        enable[0] = true;
        enable[1] = true;
        enable[2] = true;
        enable[3] = true;

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(dataProvider),
            iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, defaultModules, enable)),
            "0", false
        )));

        address[] memory withdrawableAssets = new address[](6);
        withdrawableAssets[0] = sethfi;
        withdrawableAssets[1] = frxUSD;
        withdrawableAssets[2] = liquidUsd;
        withdrawableAssets[3] = ebtc;
        withdrawableAssets[4] = liquidEth;
        withdrawableAssets[5] = liquidBtc;

        bool[] memory enable6 = new bool[](6);
        for (uint256 i = 0; i < 6; i++) enable6[i] = true;

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(cashModule),
            iToHex(abi.encodeWithSelector(ICashModule.configureWithdrawAssets.selector, withdrawableAssets, enable6)),
            "0", false
        )));

        address[] memory withdrawModules = new address[](3);
        withdrawModules[0] = liquidModuleReferrer;
        withdrawModules[1] = fraxModule;
        withdrawModules[2] = stargateModule;

        bool[] memory enable3 = new bool[](3);
        enable3[0] = true;
        enable3[1] = true;
        enable3[2] = true;

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(cashModule),
            iToHex(abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, withdrawModules, enable3)),
            "0", false
        )));

        // Set boring queues on EtherFiLiquidModuleWithReferrer (sETHFI)
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(liquidModuleReferrer),
            iToHex(abi.encodeWithSelector(EtherFiLiquidModuleWithReferrer.setLiquidAssetWithdrawQueue.selector, sethfi, sETHFIBoringQueue)),
            "0", false
        )));

        // Set boring queues on EtherFiLiquidModule (liquidEth, liquidBtc, liquidUsd)
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(liquidModule),
            iToHex(abi.encodeWithSelector(EtherFiLiquidModule.setLiquidAssetWithdrawQueue.selector, liquidEth, liquidEthBoringQueue)),
            "0", false
        )));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(liquidModule),
            iToHex(abi.encodeWithSelector(EtherFiLiquidModule.setLiquidAssetWithdrawQueue.selector, liquidBtc, liquidBtcBoringQueue)),
            "0", false
        )));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(liquidModule),
            iToHex(abi.encodeWithSelector(EtherFiLiquidModule.setLiquidAssetWithdrawQueue.selector, liquidUsd, liquidUsdBoringQueue)),
            "0", false
        )));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(liquidModule),
            iToHex(abi.encodeWithSelector(EtherFiLiquidModule.setLiquidAssetWithdrawQueue.selector, ebtc, ebtcBoringQueue)),
            "0", false
        )));

        return txs;
    }

    function _buildOracleConfigTxs(string memory txs) internal view returns (string memory) {
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
            oracle: frxUSDPriceOracle, priceFunctionCalldata: "", isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(frxUSDPriceOracle).decimals(), maxStaleness: 14 days,
            dataType: PriceProvider.ReturnType.Int256, isBaseTokenEth: false, isStableToken: true, isBaseTokenBtc: false
        });

        priceConfigs[1] = PriceProvider.Config({
            oracle: address(liquidEthAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false, oraclePriceDecimals: liquidEthAccountant.decimals(), maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256, isBaseTokenEth: true, isStableToken: false, isBaseTokenBtc: false
        });

        priceConfigs[2] = PriceProvider.Config({
            oracle: address(liquidBtcAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false, oraclePriceDecimals: liquidBtcAccountant.decimals(), maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256, isBaseTokenEth: false, isStableToken: false, isBaseTokenBtc: true
        });

        priceConfigs[3] = PriceProvider.Config({
            oracle: address(liquidUsdAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false, oraclePriceDecimals: liquidUsdAccountant.decimals(), maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256, isBaseTokenEth: false, isStableToken: false, isBaseTokenBtc: false
        });

        priceConfigs[4] = PriceProvider.Config({
            oracle: address(ebtcAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false, oraclePriceDecimals: ebtcAccountant.decimals(), maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256, isBaseTokenEth: false, isStableToken: false, isBaseTokenBtc: true
        });

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(priceProvider),
            iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, priceTokens, priceConfigs)),
            "0", false
        )));

        return txs;
    }

    function _buildDebtManagerConfigTxs(string memory txs) internal view returns (string memory) {
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(debtManager),
            iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, frxUSD,
                IDebtManager.CollateralTokenConfig({ltv: 90e18, liquidationThreshold: 95e18, liquidationBonus: 1e18}))),
            "0", false
        )));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(debtManager),
            iToHex(abi.encodeWithSelector(IDebtManager.supportBorrowToken.selector, frxUSD, uint64(1), type(uint128).max)),
            "0", false
        )));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(debtManager),
            iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, liquidEth,
                IDebtManager.CollateralTokenConfig({ltv: 50e18, liquidationThreshold: 70e18, liquidationBonus: 5e18}))),
            "0", false
        )));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(debtManager),
            iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, liquidBtc,
                IDebtManager.CollateralTokenConfig({ltv: 50e18, liquidationThreshold: 70e18, liquidationBonus: 5e18}))),
            "0", false
        )));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(debtManager),
            iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, liquidUsd,
                IDebtManager.CollateralTokenConfig({ltv: 80e18, liquidationThreshold: 90e18, liquidationBonus: 2e18}))),
            "0", false
        )));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(debtManager),
            iToHex(abi.encodeWithSelector(IDebtManager.supportBorrowToken.selector, liquidUsd, uint64(1), type(uint128).max)),
            "0", false
        )));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(debtManager),
            iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, ebtc,
                IDebtManager.CollateralTokenConfig({ltv: 52e18, liquidationThreshold: 72e18, liquidationBonus: 5e18}))),
            "0", false
        )));

        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(debtManager),
            iToHex(abi.encodeWithSelector(IDebtManager.supportBorrowToken.selector, usdt, uint64(1), type(uint128).max)),
            "0", true
        )));

        return txs;
    }

    function _assertDeployment() internal view {
        console.log("Running post-deployment assertions...");

        address rrOwner = RoleRegistry(roleRegistry).owner();
        require(rrOwner == cashControllerSafe, "CRITICAL: RoleRegistry owner changed!");
        console.log("  [OK] RoleRegistry owner unchanged");

        // Contract existence
        require(liquidModule.code.length > 0, "EtherFiLiquidModule has no code");
        require(liquidModuleReferrer.code.length > 0, "EtherFiLiquidModuleWithReferrer has no code");
        require(stargateModule.code.length > 0, "StargateModule has no code");
        require(fraxModule.code.length > 0, "FraxModule has no code");
        require(liquifierProxy.code.length > 0, "LiquidUSDLiquifierModule has no code");

        // Impl slot for proxy
        bytes32 EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        address expectedImpl = CREATE3.predictDeterministicAddress(SALT_LIQUIFIER_IMPL, NICKS_FACTORY);
        address actualImpl = address(uint160(uint256(vm.load(liquifierProxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, "LiquidUSDLiquifier impl mismatch - possible hijack");
        console.log("  [OK] LiquidUSDLiquifier impl slot verified");

        // Immutables
        require(EtherFiLiquidModule(liquidModule).weth() == weth, "LiquidModule weth wrong");
        require(EtherFiLiquidModuleWithReferrer(liquidModuleReferrer).weth() == weth, "LiquidModuleReferrer weth wrong");

        // Gnosis config effects
        require(EtherFiLiquidModuleWithReferrer(liquidModuleReferrer).liquidWithdrawQueue(sethfi) == sETHFIBoringQueue, "boring queue not set");
        require(PriceProvider(priceProvider).price(frxUSD) != 0, "frxUSD price is 0");
        require(PriceProvider(priceProvider).price(liquidEth) != 0, "liquidEth price is 0");
        require(IDebtManager(debtManager).isCollateralToken(frxUSD), "frxUSD not collateral");
        require(IDebtManager(debtManager).isCollateralToken(liquidEth), "liquidEth not collateral");
        require(IDebtManager(debtManager).isCollateralToken(ebtc), "ebtc not collateral");

        console.log("  All assertions passed!");
    }
}
