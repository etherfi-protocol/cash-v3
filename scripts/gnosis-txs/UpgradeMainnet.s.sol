// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {EtherFiSafe} from "../../src/safe/EtherFiSafe.sol";
import {EtherFiDataProvider} from "../../src/data-provider/EtherFiDataProvider.sol";
import {EtherFiSafeFactory, BeaconFactory} from "../../src/safe/EtherFiSafeFactory.sol";
import {CashEventEmitter} from "../../src/modules/cash/CashEventEmitter.sol";
import {OpenOceanSwapModule} from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import {CashModuleCore} from "../../src/modules/cash/CashModuleCore.sol";
import {CashModuleSetters} from "../../src/modules/cash/CashModuleSetters.sol";
import { PriceProvider, IAggregatorV3 } from "../../src/oracle/PriceProvider.sol";
import { ILayerZeroTeller, AccountantWithRateProviders } from "../../src/interfaces/ILayerZeroTeller.sol";
import { IDebtManager } from "../../src/interfaces/IDebtManager.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract UpgradeMainnet is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address openOceanSwapRouter = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;

    IERC20 public weth = IERC20(0x5300000000000000000000000000000000000004);
    IERC20 public weEth = IERC20(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    IERC20 public usdc = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    IERC20 public usdt = IERC20(0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df);
    IERC20 public dai = IERC20(0xcA77eB3fEFe3725Dc33bccB54eDEFc3D9f764f97);
    IERC20 public wbtc = IERC20(0x3C1BCa5a656e69edCD0D4E36BEbb3FcDAcA60Cf1);
    IERC20 public usde = IERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);

    address public btcUsdOracle = 0x91429ddc50B38bAF3Ba9CB5eB0275507Ac65CBF4;
    
    IERC20 public liquidEth = IERC20(0xf0bb20865277aBd641a307eCe5Ee04E79073416C);
    ILayerZeroTeller public liquidEthTeller = ILayerZeroTeller(0x9AA79C84b79816ab920bBcE20f8f74557B514734);
    
    IERC20 public liquidUsd = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    ILayerZeroTeller public liquidUsdTeller = ILayerZeroTeller(0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387);
    
    IERC20 public liquidBtc = IERC20(0x5f46d540b6eD704C3c8789105F30E075AA900726);
    ILayerZeroTeller public liquidBtcTeller = ILayerZeroTeller(0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353);

    IERC20 public eUsd = IERC20(0x939778D83b46B456224A33Fb59630B11DEC56663);
    ILayerZeroTeller public eUsdTeller = ILayerZeroTeller(0xCc9A7620D0358a521A068B444846E3D5DebEa8fA);

    address[] public topUpWallets;
    address public etherFiWallet = 0xB42833d6edd1241474D33ea99906fD4CBE893730; // Rupert generated
    address public topUpDepositorWallet = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790; // JV gave

    /// @notice Role identifier for EtherFi wallet access control
    bytes32 public constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");

    /// @notice Role identifier for accounts authorized to deposit tokens
    bytes32 public constant TOP_UP_DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice Role identifier for accounts authorized to top up user safes
    bytes32 public constant TOP_UP_ROLE = keccak256("TOP_UP_ROLE");

    bytes32 public constant ETHERFI_SAFE_FACTORY_ADMIN_ROLE = keccak256("ETHERFI_SAFE_FACTORY_ADMIN_ROLE");

    address factory;
    address dataProvider;
    address cashModule;
    address cashEventEmitter;
    address priceProvider;
    address debtManager;
    address roleRegistry;
    address oldOpenOceanSwapModule;
    address factoryImpl;
    address safeImpl;
    address cashModuleCoreImpl;
    address cashModuleSettersImpl;
    address cashEventEmitterImpl;
    address priceProviderImpl;
    address openOceanSwapModule;

    function run() public {
        string memory deployments = readDeploymentFile();

        string memory chainId = vm.toString(block.chainid);

        vm.startBroadcast();

        factory = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiSafeFactory")
        );
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        cashEventEmitter = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashEventEmitter")
        );
        priceProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PriceProvider")
        );
        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );
        roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );
        oldOpenOceanSwapModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "OpenOceanSwapModule")
        );

        factoryImpl = address(new EtherFiSafeFactory());
        safeImpl = address(new EtherFiSafe(dataProvider));
        cashModuleCoreImpl = address(new CashModuleCore(dataProvider));
        cashModuleSettersImpl = address(new CashModuleSetters(dataProvider));
        cashEventEmitterImpl = address(new CashEventEmitter(cashModule));
        priceProviderImpl = address(new PriceProvider());

        openOceanSwapModule = address(new OpenOceanSwapModule(openOceanSwapRouter, dataProvider));

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));
        
        txs = getUpgrades(txs);

        address[] memory modules = new address[](2);
        modules[0] = oldOpenOceanSwapModule;
        modules[1] = openOceanSwapModule;

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = false;   
        shouldWhitelist[1] = true;   

        string memory updateModulesOnDataProvider = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, modules, shouldWhitelist));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), updateModulesOnDataProvider, "0", false)));

        string memory setTokenConfig = setupPriceProviderConfig();
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), setTokenConfig, "0", false)));

        txs = configureCollateralAssets(txs);

        txs = grantRoles(txs);

        vm.createDir("./output", true);
        string memory path = "./output/UpgradeMainnet.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        /// below here is just a test
        executeGnosisTransactionBundle(path);
    }

    function getUpgrades(string memory txs) internal view returns (string memory) {
        string memory safeFactoryUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, factoryImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(factory), safeFactoryUpgrade, "0", false)));

        string memory safeImplUpgrade = iToHex(abi.encodeWithSelector(BeaconFactory.upgradeBeaconImplementation.selector, safeImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(factory), safeImplUpgrade, "0", false)));

        string memory priceProviderUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, priceProviderImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(priceProvider), priceProviderUpgrade, "0", false)));

        string memory cashModuleCoreUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashModuleCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), cashModuleCoreUpgrade, "0", false)));

        string memory cashModuleAdminUpgrade = iToHex(abi.encodeWithSelector(CashModuleCore.setCashModuleSettersAddress.selector, cashModuleSettersImpl));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), cashModuleAdminUpgrade, "0", false)));
        
        string memory cashEventEmitterUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, cashEventEmitterImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashEventEmitter), cashEventEmitterUpgrade, "0", false)));

        return txs;
    }

    function grantRoles(string memory txs) internal  returns (string memory) {
        string memory grantEtherFiWalletRole = iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, ETHER_FI_WALLET_ROLE, etherFiWallet));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantEtherFiWalletRole, "0", false)));
        
        string memory grantEtherFiSafeFactoryAdminRole = iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, ETHERFI_SAFE_FACTORY_ADMIN_ROLE, etherFiWallet));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantEtherFiSafeFactoryAdminRole, "0", false)));
        
        string memory grantTopUpDepositorRole = iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, TOP_UP_DEPOSITOR_ROLE, topUpDepositorWallet));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantTopUpDepositorRole, "0", false)));

        topUpWallets.push(0xf96f8E03615f7b71e0401238D28bb08CceECBae7);
        topUpWallets.push(0xB82C61E4A4b4E5524376BC54013a154b2e55C5c8);
        topUpWallets.push(0xC73019F991dCBCc899d6B76000FdcCc99a208235);
        topUpWallets.push(0x93D540Dd6893bF9eA8ECD57fce32cB49b2D1B510);
        topUpWallets.push(0x29ebBC872CE1AF08508A65053b725Beadba43C48);
        topUpWallets.push(0x957a670ecE294dDf71c6A9C030432Db013082fd1);
        topUpWallets.push(0xFb5e703DAe21C594246f0311AE0361D1dFe250b1);
        topUpWallets.push(0xab00819212917dA43A81b696877Cc0BcA798b613);
        topUpWallets.push(0x5609BB231ec547C727D65eb6811CCd0C731339De);
        topUpWallets.push(0xcf1369d6CdD148AF5Af04F4002dee9A00c7F8Ae9);

        for (uint256 i = 0; i < topUpWallets.length; ++i) {
            bool isLast = i == topUpWallets.length - 1;
            string memory grantTopUpRole = iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, TOP_UP_ROLE, topUpWallets[i]));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantTopUpRole, "0", isLast)));
        }
        
        return txs;
    }

    function setupPriceProviderConfig() internal view returns (string memory) {
        PriceProvider.Config memory btcUsdConfig = PriceProvider.Config({
            oracle: btcUsdOracle,
            priceFunctionCalldata: "",
            isChainlinkType: true,
            oraclePriceDecimals: IAggregatorV3(btcUsdOracle).decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        AccountantWithRateProviders liquidEthAccountant = liquidEthTeller.accountant();

        PriceProvider.Config memory liquidEthConfig = PriceProvider.Config({
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

        AccountantWithRateProviders liquidBtcAccountant = liquidBtcTeller.accountant();

        PriceProvider.Config memory liquidBtcConfig = PriceProvider.Config({
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

        AccountantWithRateProviders liquidUsdAccountant = liquidUsdTeller.accountant();

        PriceProvider.Config memory liquidUsdConfig = PriceProvider.Config({
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

        AccountantWithRateProviders eUsdAccountant = eUsdTeller.accountant();

        PriceProvider.Config memory eUsdConfig = PriceProvider.Config({
            oracle: address(eUsdAccountant),
            priceFunctionCalldata: abi.encodeWithSelector(AccountantWithRateProviders.getRate.selector),
            isChainlinkType: false,
            oraclePriceDecimals: eUsdAccountant.decimals(),
            maxStaleness: 2 days,
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });

        address[] memory assets = new address[](5);
        assets[0] = address(wbtc);
        assets[1] = address(liquidEth);
        assets[2] = address(liquidBtc);
        assets[3] = address(liquidUsd);
        assets[4] = address(eUsd);

        PriceProvider.Config[] memory config = new PriceProvider.Config[](5);
        config[0] = btcUsdConfig;
        config[1] = liquidEthConfig;
        config[2] = liquidBtcConfig;
        config[3] = liquidUsdConfig;
        config[4] = eUsdConfig;

        return iToHex(abi.encodeWithSelector(PriceProvider.setTokenConfig.selector, assets, config));
    }

    function configureCollateralAssets(string memory txs) internal view returns (string memory) {
        IDebtManager.CollateralTokenConfig memory liquidEthConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 1e18
        }); 
        IDebtManager.CollateralTokenConfig memory liquidBtcConfig = IDebtManager.CollateralTokenConfig({
            ltv: 50e18,
            liquidationThreshold: 80e18,
            liquidationBonus: 1e18
        }); 
        IDebtManager.CollateralTokenConfig memory liquidUsdConfig = IDebtManager.CollateralTokenConfig({
            ltv: 80e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 1e18
        }); 
        IDebtManager.CollateralTokenConfig memory eUsdConfig = IDebtManager.CollateralTokenConfig({
            ltv: 80e18,
            liquidationThreshold: 90e18,
            liquidationBonus: 1e18
        }); 

        string memory setLiquidEthConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, liquidEth, liquidEthConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setLiquidEthConfig, "0", false)));
        
        string memory setLiquidBtcConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, liquidBtc, liquidBtcConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setLiquidBtcConfig, "0", false)));
        
        string memory setLiquidUsdConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, liquidUsd, liquidUsdConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setLiquidUsdConfig, "0", false)));
        
        string memory setEUsdConfig = iToHex(abi.encodeWithSelector(IDebtManager.supportCollateralToken.selector, eUsd, eUsdConfig));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), setEUsdConfig, "0", false)));

        return txs;
    }
}
