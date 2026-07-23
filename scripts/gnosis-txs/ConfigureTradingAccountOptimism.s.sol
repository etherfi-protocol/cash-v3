// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TradingAccountCreate3, TradingAccountProdConfig as C } from "../trading-account/TradingAccountProdConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @notice Generates and fork-simulates the OP Safe bundle after both swap modules are deployed.
contract ConfigureTradingAccountOptimism is GnosisHelpers, Utils, TradingAccountCreate3 {
    using stdJson for string;

    bytes32 private constant ACROSS_ADMIN_ROLE = keccak256("ACROSS_SWAP_MODULE_ADMIN_ROLE");
    bytes32 private constant ENSO_ADMIN_ROLE = keccak256("ENSO_SWAP_MODULE_ADMIN_ROLE");

    function run() external {
        require(block.chainid == 10, "must run on Optimism");

        string memory deployments = readDeploymentFile();
        address roleRegistry = deployments.readAddress(".addresses.RoleRegistry");
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        address cashModule = deployments.readAddress(".addresses.CashModule");
        address across = _predict(C.SALT_ACROSS_PROXY);
        address enso = _predict(C.SALT_ENSO_PROXY);

        require(across.code.length > 0, "Across deployment missing");
        require(enso.code.length > 0, "Enso deployment missing");

        address[] memory modules = new address[](2);
        modules[0] = across;
        modules[1] = enso;
        bool[] memory enable = new bool[](2);
        enable[0] = true;
        enable[1] = true;

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(C.OPERATING_SAFE));
        txs = _appendRole(txs, roleRegistry, ACROSS_ADMIN_ROLE, C.OPERATING_SAFE);
        txs = _appendRole(txs, roleRegistry, ENSO_ADMIN_ROLE, C.OPERATING_SAFE);
        txs = _append(txs, across, abi.encodeWithSelector(AcrossSwapModule.setPeriphery.selector, C.ACROSS_PERIPHERY));
        txs = _append(txs, dataProvider, abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, enable));
        bytes memory configureWithdrawals = abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, modules, enable);
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(cashModule), iToHex(configureWithdrawals), "0", true));

        vm.createDir("./output", true);
        string memory path = "./output/ConfigureTradingAccountOptimism.json";
        vm.writeFile(path, txs);
        executeGnosisTransactionBundle(path);

        require(RoleRegistry(roleRegistry).hasRole(ACROSS_ADMIN_ROLE, C.OPERATING_SAFE), "missing Across role");
        require(RoleRegistry(roleRegistry).hasRole(ENSO_ADMIN_ROLE, C.OPERATING_SAFE), "missing Enso role");
        require(AcrossSwapModule(across).getPeriphery() == C.ACROSS_PERIPHERY, "periphery mismatch");
        require(EtherFiDataProvider(dataProvider).isDefaultModule(across), "Across not default");
        require(EtherFiDataProvider(dataProvider).isDefaultModule(enso), "Enso not default");

        address[] memory withdrawModules = ICashModule(cashModule).getWhitelistedModulesCanRequestWithdraw();
        require(_contains(withdrawModules, across), "Across cannot request withdrawal");
        require(_contains(withdrawModules, enso), "Enso cannot request withdrawal");
    }

    function _append(string memory txs, address to, bytes memory data) private pure returns (string memory) {
        return string.concat(txs, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", false));
    }

    function _appendRole(string memory txs, address registry, bytes32 role, address account) private pure returns (string memory) {
        return _append(txs, registry, abi.encodeWithSelector(RoleRegistry.grantRole.selector, role, account));
    }

    function _contains(address[] memory values, address needle) private pure returns (bool) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == needle) return true;
        }
        return false;
    }
}
