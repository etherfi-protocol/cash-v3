// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { CashLens } from "../../src/modules/cash/CashLens.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title UpgradeCashLensWithPendingHolds
 * @notice Gnosis Safe batch that upgrades CashLens to an implementation that carries a live
 *         PendingHoldsModule immutable, enabling spendable() / getBalances() to deduct pending holds.
 *
 * @dev Prerequisites:
 *   - DeployPendingHoldsModule has been run and its proxy address is in deployments.json
 *     as "PendingHoldsModule".
 *   - UpgradeCashModuleWithPendingHolds has been executed (CashModule now recognises PHM).
 *
 * @dev Because pendingHoldsModule is an immutable on CashLens, a new implementation must be
 *      deployed and the proxy upgraded — it cannot be set via a setter.
 */
contract UpgradeCashLensWithPendingHolds is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        vm.startBroadcast();

        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
        );
        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        address cashLens = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashLens")
        );
        address phmProxy = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "PendingHoldsModule")
        );

        // Deploy new CashLens implementation with live PendingHoldsModule address
        address newCashLensImpl = address(new CashLens(cashModule, dataProvider, phmProxy));

        // --- Build Gnosis Safe transaction batch ---
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // Single tx: upgrade CashLens proxy to new implementation
        string memory upgradeLensCalldata = iToHex(
            abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, newCashLensImpl, "")
        );
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cashLens), upgradeLensCalldata, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/UpgradeCashLensWithPendingHolds.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        executeGnosisTransactionBundle(path);
    }
}
