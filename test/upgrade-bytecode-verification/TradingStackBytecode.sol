// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/Test.sol";

import { ContractCodeChecker } from "../../scripts/utils/ContractCodeChecker.sol";
import { Utils } from "../utils/Utils.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";

/// @notice Shared bytecode helpers, and the checks for the trading stack contracts that exist on every
///         chain that has a trading account (RoleRegistry, EtherFiDataProvider, TradingSafeFactory and
///         the TradingSafe beacon implementation). Implementations are read from the EIP-1967 slot of the
///         proxies recorded in deployments/mainnet/<chain>/trading-account.json.
abstract contract TradingStackBytecode is ContractCodeChecker, Utils {
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    string internal trading;

    function _loadTrading() internal {
        trading = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/", vm.toString(block.chainid), "/trading-account.json"));
    }

    function _tradingAddr(string memory key) internal view returns (address) {
        return stdJson.readAddress(trading, string.concat(".", key));
    }

    function test_verifyBytecode_TradingRoleRegistry() public {
        address local = address(new RoleRegistry(_tradingAddr("EtherFiDataProvider")));
        _verify("trading RoleRegistry", _getImpl(_tradingAddr("RoleRegistry")), local);
    }

    function test_verifyBytecode_TradingEtherFiDataProvider() public {
        address local = address(new EtherFiDataProvider());
        _verify("trading EtherFiDataProvider", _getImpl(_tradingAddr("EtherFiDataProvider")), local);
    }

    function test_verifyBytecode_TradingSafeFactory() public {
        address local = address(new TradingSafeFactory());
        _verify("TradingSafeFactory", _getImpl(_tradingAddr("TradingSafeFactory")), local);
    }

    function test_verifyBytecode_TradingSafe() public {
        address beacon = TradingSafeFactory(_tradingAddr("TradingSafeFactory")).beacon();
        address deployed = UpgradeableBeacon(beacon).implementation();
        address local = address(new TradingSafe(_tradingAddr("EtherFiDataProvider")));
        _verify("TradingSafe", deployed, local);
    }

    // ---- Helpers ----

    function _getImpl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }

    function _verify(string memory name, address deployed, address local) internal {
        console.log("------", name, "------");
        console.log("  Deployed:", deployed);
        console.log("  Local:   ", local);
        requireCodeMatchAllowingAddressEmbeds(name, deployed, local);
    }

    function _tryEnv(string memory key, string memory fallback_) internal view returns (string memory) {
        try vm.envString(key) returns (string memory val) {
            return bytes(val).length > 0 ? val : fallback_;
        } catch {
            return fallback_;
        }
    }
}
