// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { AcrossSwapModule } from "../src/across/AcrossSwapModule.sol";
import { BeaconFactory } from "../src/beacon-factory/BeaconFactory.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { EnsoSwapModule } from "../src/enso/EnsoSwapModule.sol";
import { PriceProviderV2 } from "../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../src/top-up/TopUp.sol";
import { TopUpFactory } from "../src/top-up/TopUpFactory.sol";
import { TradingLens } from "../src/trading-safe/TradingLens.sol";
import { TradingSafe } from "../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../src/trading-safe/TradingSafeFactory.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "./trading-account/TradingAccountProdConfig.sol";
import { GnosisHelpers } from "./utils/GnosisHelpers.sol";
import { Utils } from "./utils/Utils.sol";

/// @notice Rebuilds production implementations locally and compares their runtime bytecode.
/// @dev Run after predeployment. On Ethereum, run after the Gnosis upgrade to also verify
///      the existing TopUp factory and beacon now point to the audited implementations.
contract VerifyTradingAccountProdBytecode is Script, GnosisHelpers, Utils, TradingAccountCreate3 {
    using stdJson for string;

    function run() external {
        if (block.chainid == 1) _verifyEthereum();
        else if (block.chainid == 10) _verifyOptimism();
        else revert("unsupported chain");
    }

    function _verifyEthereum() private {
        address dataProvider = _predict(C.SALT_DATA_PROVIDER_PROXY);
        address roleRegistry = _predict(C.SALT_ROLE_REGISTRY_PROXY);
        address priceProvider = _predict(C.SALT_PRICE_PROVIDER_PROXY);

        _verify(C.SALT_ROLE_REGISTRY_IMPL, address(new RoleRegistry(dataProvider)));
        _verify(C.SALT_PRICE_PROVIDER_IMPL, address(new PriceProviderV2()));
        _verify(C.SALT_TRADING_SAFE_IMPL, address(new TradingSafe(dataProvider)));
        _verify(C.SALT_TRADING_SAFE_FACTORY_IMPL, address(new TradingSafeFactory()));
        _verify(C.SALT_TRADING_LENS_IMPL, address(new TradingLens(priceProvider)));
        _verify(C.SALT_DATA_PROVIDER_IMPL, address(new EtherFiDataProvider()));
        _verify(C.SALT_ACROSS_IMPL, address(new AcrossSwapModule(dataProvider)));
        _verify(C.SALT_ENSO_IMPL, address(new EnsoSwapModule(dataProvider)));
        _verify(C.SALT_TOPUP_FACTORY_IMPL, address(new TopUpFactory()));
        _verify(C.SALT_TOPUP_IMPL, address(new TopUp(C.ETH_WETH)));

        _requireProxyImpl(C.SALT_ROLE_REGISTRY_PROXY, C.SALT_ROLE_REGISTRY_IMPL);
        _requireProxyImpl(C.SALT_PRICE_PROVIDER_PROXY, C.SALT_PRICE_PROVIDER_IMPL);
        _requireProxyImpl(C.SALT_TRADING_SAFE_FACTORY_PROXY, C.SALT_TRADING_SAFE_FACTORY_IMPL);
        _requireProxyImpl(C.SALT_TRADING_LENS_PROXY, C.SALT_TRADING_LENS_IMPL);
        _requireProxyImpl(C.SALT_DATA_PROVIDER_PROXY, C.SALT_DATA_PROVIDER_IMPL);
        _requireProxyImpl(C.SALT_ACROSS_PROXY, C.SALT_ACROSS_IMPL);
        _requireProxyImpl(C.SALT_ENSO_PROXY, C.SALT_ENSO_IMPL);

        string memory deployments = readTopUpSourceDeployment();
        address topUpFactory = deployments.readAddress(".addresses.TopUpSourceFactory");
        if (_proxyImpl(topUpFactory) != _predict(C.SALT_TOPUP_FACTORY_IMPL)) {
            executeGnosisTransactionBundle("./output/ConfigureTradingAccountEthereum.json");
        }
        require(_proxyImpl(topUpFactory) == _predict(C.SALT_TOPUP_FACTORY_IMPL), "TopUpFactory implementation mismatch");
        address beacon = BeaconFactory(topUpFactory).beacon();
        require(UpgradeableBeacon(beacon).implementation() == _predict(C.SALT_TOPUP_IMPL), "TopUp implementation mismatch");

        require(address(RoleRegistry(roleRegistry).etherFiDataProvider()) == dataProvider, "RoleRegistry immutable mismatch");
    }

    function _verifyOptimism() private {
        string memory deployments = readDeploymentFile();
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");

        _verify(C.SALT_ACROSS_IMPL, address(new AcrossSwapModule(dataProvider)));
        _verify(C.SALT_ENSO_IMPL, address(new EnsoSwapModule(dataProvider)));
        _requireProxyImpl(C.SALT_ACROSS_PROXY, C.SALT_ACROSS_IMPL);
        _requireProxyImpl(C.SALT_ENSO_PROXY, C.SALT_ENSO_IMPL);
    }

    function _verify(bytes32 salt, address local) private view {
        address deployed = _predict(salt);
        bytes memory expected = local.code;
        bytes memory actual = deployed.code;

        require(actual.length > 0, "deployed implementation missing");
        require(expected.length == actual.length, "implementation bytecode length mismatch");

        // OpenZeppelin UUPS implementations embed `address(this)` as an immutable. A local
        // reconstruction necessarily has a different address, so normalize only that exact
        // immutable before enforcing a strict full-runtime-bytecode match.
        _replaceAddress(expected, local, deployed);
        require(keccak256(expected) == keccak256(actual), "implementation runtime bytecode mismatch");
    }

    function _requireProxyImpl(bytes32 proxySalt, bytes32 implSalt) private view {
        require(_proxyImpl(_predict(proxySalt)) == _predict(implSalt), "proxy implementation mismatch");
    }

    function _proxyImpl(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, C.EIP1967_IMPL_SLOT))));
    }

    function _replaceAddress(bytes memory code, address from, address to) private pure {
        bytes20 needle = bytes20(from);
        bytes20 replacement = bytes20(to);
        if (needle == replacement || code.length < 20) return;

        for (uint256 i = 0; i <= code.length - 20; ++i) {
            bool matches = true;
            for (uint256 j = 0; j < 20; ++j) {
                if (code[i + j] != needle[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                for (uint256 j = 0; j < 20; ++j) {
                    code[i + j] = replacement[j];
                }
                i += 19;
            }
        }
    }
}
