// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title UpgradeCashModuleWithPendingHolds
 * @notice Gnosis Safe batch that:
 *   1. Upgrades CashModule to new Core implementation (adds rawSpendable() and removeHold() call in spend()).
 *   2. Wires in the new CashModuleSetters implementation (adds withdrawal guard + setPendingHoldsModule()).
 *   3. Calls setPendingHoldsModule() to link the deployed PendingHoldsModule proxy.
 *
 * @dev Prerequisites:
 *   - DeployPendingHoldsModule has been run and its proxy address is in deployments.json
 *     as "PendingHoldsModule".
 *   - cashControllerSafe has CASH_MODULE_CONTROLLER_ROLE on the RoleRegistry.
 *
 * @dev Atomic safety: steps 1-3 execute in a single Gnosis batch so there is no window where
 *   CashModule points to the new Core but the pending-holds withdrawal guard is missing.
 */
contract UpgradeCashModuleWithPendingHolds is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        vm.startBroadcast();

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        address phmProxy = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PendingHoldsModule")
        );

        // Deploy new implementations (broadcast pays gas; Safe executes the upgrades)
        address newCoreImpl = address(new CashModuleCore(dataProvider));
        address newSettersImpl = address(new CashModuleSetters(dataProvider));

        // --- Build Gnosis Safe transaction batch ---
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // Tx 1: upgrade CashModule proxy to new Core implementation
        string memory upgradeCoreCalldata = iToHex(
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, newCoreImpl, "")
        );
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), upgradeCoreCalldata, "0", false)));

        // Tx 2: point CashModule at new Setters implementation
        string memory setSettersCalldata = iToHex(
            abi.encodeWithSelector(ICashModule.setCashModuleSettersAddress.selector, newSettersImpl)
        );
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), setSettersCalldata, "0", false)));

        // Tx 3: wire PendingHoldsModule into CashModule (routed via fallback → CashModuleSetters)
        string memory setPhmCalldata = iToHex(
            abi.encodeWithSelector(ICashModule.setPendingHoldsModule.selector, phmProxy)
        );
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashModule), setPhmCalldata, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/UpgradeCashModuleWithPendingHolds.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        executeGnosisTransactionBundle(path);
    }
}
