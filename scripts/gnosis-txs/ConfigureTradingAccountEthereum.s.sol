// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "../trading-account/TradingAccountProdConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @notice Generates and fork-simulates the Ethereum Safe bundle after all CREATE3 deployments exist.
contract ConfigureTradingAccountEthereum is GnosisHelpers, Utils, TradingAccountCreate3 {
    using stdJson for string;

    bytes32 private constant ACROSS_ADMIN_ROLE = keccak256("ACROSS_SWAP_MODULE_ADMIN_ROLE");
    bytes32 private constant ENSO_ADMIN_ROLE = keccak256("ENSO_SWAP_MODULE_ADMIN_ROLE");
    bytes32 private constant TRADING_FACTORY_ADMIN_ROLE = keccak256("TRADING_SAFE_FACTORY_ADMIN_ROLE");
    bytes32 private constant TRADING_REDIRECT_ROLE = keccak256("TRADING_SAFE_REDIRECT_ROLE");
    bytes32 private constant TOPUP_REDIRECT_ROLE = keccak256("TOPUP_FACTORY_REDIRECT_ROLE");
    bytes32 private constant TRADING_LENS_ADMIN_ROLE = keccak256("TRADING_LENS_ADMIN_ROLE");
    bytes32 private constant DATA_PROVIDER_ADMIN_ROLE = keccak256("DATA_PROVIDER_ADMIN_ROLE");
    bytes32 private constant PRICE_PROVIDER_ADMIN_ROLE = keccak256("PRICE_PROVIDER_ADMIN_ROLE");

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");

        string memory topUpDeployments = readTopUpSourceDeployment();
        address topUpFactory = topUpDeployments.readAddress(".addresses.TopUpSourceFactory");
        address topUpRoleRegistry = topUpDeployments.readAddress(".addresses.RoleRegistry");

        address roleRegistry = _predict(C.SALT_ROLE_REGISTRY_PROXY);
        address priceProvider = _predict(C.SALT_PRICE_PROVIDER_PROXY);
        address dataProvider = _predict(C.SALT_DATA_PROVIDER_PROXY);
        address tradingFactory = _predict(C.SALT_TRADING_SAFE_FACTORY_PROXY);
        address tradingLens = _predict(C.SALT_TRADING_LENS_PROXY);
        address across = _predict(C.SALT_ACROSS_PROXY);
        address topUpFactoryImpl = _predict(C.SALT_TOPUP_FACTORY_IMPL);
        address topUpImpl = _predict(C.SALT_TOPUP_IMPL);

        _requireDeployed(roleRegistry);
        _requireDeployed(priceProvider);
        _requireDeployed(dataProvider);
        _requireDeployed(tradingFactory);
        _requireDeployed(tradingLens);
        _requireDeployed(across);
        _requireDeployed(_predict(C.SALT_ENSO_PROXY));
        _requireDeployed(topUpFactoryImpl);
        _requireDeployed(topUpImpl);

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));

        txs = _append(txs, topUpFactory, abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, topUpFactoryImpl, ""));
        txs = _append(txs, topUpFactory, abi.encodeWithSelector(BeaconFactory.upgradeBeaconImplementation.selector, topUpImpl));
        txs = _append(txs, tradingFactory, abi.encodeWithSelector(TradingSafeFactory.setTopUpFactory.selector, topUpFactory));
        txs = _append(txs, tradingFactory, abi.encodeWithSelector(TradingSafeFactory.setTradingLens.selector, tradingLens));
        txs = _append(txs, topUpFactory, abi.encodeWithSelector(TopUpFactory.setTradingSafeFactory.selector, tradingFactory));

        txs = _appendRole(txs, topUpRoleRegistry, TOPUP_REDIRECT_ROLE, C.OPERATING_ADMIN);
        txs = _appendRole(txs, roleRegistry, TRADING_FACTORY_ADMIN_ROLE, C.OPERATING_ADMIN);
        txs = _appendRole(txs, roleRegistry, TRADING_REDIRECT_ROLE, C.OPERATING_ADMIN);
        txs = _appendRole(txs, roleRegistry, ACROSS_ADMIN_ROLE, C.OPERATING_SAFE);
        txs = _appendRole(txs, roleRegistry, ENSO_ADMIN_ROLE, C.OPERATING_SAFE);
        txs = _appendRole(txs, roleRegistry, TRADING_LENS_ADMIN_ROLE, C.OPERATING_SAFE);
        txs = _appendRole(txs, roleRegistry, DATA_PROVIDER_ADMIN_ROLE, C.OPERATING_SAFE);
        txs = _appendRole(txs, roleRegistry, PRICE_PROVIDER_ADMIN_ROLE, C.OPERATING_SAFE);

        txs = _append(txs, across, abi.encodeWithSelector(AcrossSwapModule.setPeriphery.selector, C.ACROSS_PERIPHERY));

        address[] memory tokens = C.supportedTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            bytes memory data = abi.encodeWithSelector(TradingLens.addSupportedToken.selector, tokens[i]);
            bool isLast = i == tokens.length - 1;
            txs = string.concat(txs, _getGnosisTransaction(addressToHex(tradingLens), iToHex(data), "0", isLast));
        }

        vm.createDir("./output", true);
        string memory path = "./output/ConfigureTradingAccountEthereum.json";
        vm.writeFile(path, txs);
        executeGnosisTransactionBundle(path);

        require(address(uint160(uint256(vm.load(topUpFactory, C.EIP1967_IMPL_SLOT)))) == topUpFactoryImpl, "TopUpFactory implementation mismatch");
        address topUpBeacon = BeaconFactory(topUpFactory).beacon();
        require(UpgradeableBeacon(topUpBeacon).implementation() == topUpImpl, "TopUp implementation mismatch");
        require(TopUpFactory(payable(topUpFactory)).tradingSafeFactory() == tradingFactory, "TopUp link mismatch");
        require(TradingSafeFactory(tradingFactory).topUpFactory() == topUpFactory, "factory TopUp link mismatch");
        require(TradingSafeFactory(tradingFactory).tradingLens() == tradingLens, "factory lens link mismatch");
        require(AcrossSwapModule(across).getPeriphery() == C.ACROSS_PERIPHERY, "Across periphery mismatch");
        require(RoleRegistry(topUpRoleRegistry).hasRole(TOPUP_REDIRECT_ROLE, C.OPERATING_ADMIN), "missing TopUp redirect role");
        require(RoleRegistry(roleRegistry).hasRole(TRADING_FACTORY_ADMIN_ROLE, C.OPERATING_ADMIN), "missing trading factory role");
        require(RoleRegistry(roleRegistry).hasRole(TRADING_REDIRECT_ROLE, C.OPERATING_ADMIN), "missing trading redirect role");
        require(EtherFiDataProvider(dataProvider).getPriceProvider() == priceProvider, "price provider mismatch");
        for (uint256 i = 0; i < tokens.length; ++i) {
            require(TradingLens(tradingLens).isSupportedToken(tokens[i]), "supported token missing");
            require(PriceProviderV2(priceProvider).tokenConfig(tokens[i]).oracle == address(0), "unexpected oracle");
        }
    }

    function _append(string memory txs, address to, bytes memory data) private pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", false));
    }

    function _appendRole(string memory txs, address registry, bytes32 role, address account) private pure returns (string memory) {
        return _append(txs, registry, abi.encodeWithSelector(RoleRegistry.grantRole.selector, role, account));
    }

    function _requireDeployed(address target) private view {
        require(target.code.length > 0, "required CREATE3 deployment missing");
    }
}
