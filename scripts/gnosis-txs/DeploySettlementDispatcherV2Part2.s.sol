// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test, console } from "forge-std/Test.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { DebtManagerCore } from "../../src/debt-manager/DebtManagerCore.sol";
import { SettlementDispatcherV2 } from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract DeploySettlementDispatcherV2Part2 is Utils, Test, GnosisHelpers {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address constant REFUND_WALLET = 0xDe2fea8fDeb5643DfEFCbD0af8BE0a2925a53aC8;

    address debtManager;
    address settlementDispatcherV2;
    address dataProvider;

    address debtManagerCoreImpl;

    function run() public {
        string memory deployments = readDeploymentFile();
        vm.startBroadcast();

        debtManager = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        );
        settlementDispatcherV2 = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "SettlementDispatcherCardOrder")
        );
        dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        require(debtManager != address(0), "Invalid debtManager");
        require(settlementDispatcherV2 != address(0), "Invalid settlementDispatcherV2");
        require(dataProvider != address(0), "Invalid dataProvider");

        debtManagerCoreImpl = address(new DebtManagerCore(dataProvider));

        console.log("DebtManagerCore Implementation:", debtManagerCoreImpl);

        string memory txs = getGnosisTransactions();

        vm.createDir("./output", true);
        string memory path = "./output/DeploySettlementDispatcherV2_part2.json";
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        executeGnosisTransactionBundle(path);
    }

    function getGnosisTransactions() internal view returns (string memory) {
        string memory chainId = vm.toString(block.chainid);
        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        // Upgrade DebtManagerCore
        string memory upgradeDebtManager = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, debtManagerCoreImpl, ""));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(debtManager), upgradeDebtManager, "0", false)));

        // Set refund wallet for SettlementDispatcherV2
        string memory setRefundWallet = iToHex(abi.encodeWithSelector(SettlementDispatcherV2.setRefundWallet.selector, REFUND_WALLET));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(settlementDispatcherV2), setRefundWallet, "0", true)));

        return txs;
    }
}

