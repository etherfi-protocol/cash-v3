// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";

import {EtherFiSafeFactory} from "../../src/safe/EtherFiSafeFactory.sol";
import {GnosisHelpers} from "../utils/GnosisHelpers.sol";
import {Utils} from "../utils/Utils.sol";

/**
 * @title UpgradeSafeImplOneInch
 * @notice Generates a Gnosis Safe transaction to upgrade the EtherFiSafe beacon implementation
 *
 *      ENV=mainnet NEW_SAFE_IMPL=0x... forge script scripts/gnosis-txs/UpgradeSafeImplOneInch.s.sol --rpc-url <optimism_rpc>
 */
contract UpgradeSafeImplOneInch is GnosisHelpers, Utils {
    // Prod multisig (roleRegistry owner + DATA_PROVIDER_ADMIN_ROLE holder)
    address constant multisig = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        address newSafeImpl = vm.envAddress("NEW_SAFE_IMPL");

        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        address safeFactory = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiSafeFactory")
        );

        // Build Gnosis transaction: safeFactory.upgradeBeaconImplementation(newSafeImpl)
        string memory txs = _getGnosisHeader(chainId, addressToHex(multisig));

        string memory upgradeData = iToHex(
            abi.encodeWithSelector(EtherFiSafeFactory.upgradeBeaconImplementation.selector, newSafeImpl)
        );
        txs = string(abi.encodePacked(
            txs,
            _getGnosisTransaction(addressToHex(safeFactory), upgradeData, "0", true)
        ));

        vm.createDir("./output", true);
        string memory path = "./output/UpgradeSafeImplOneInch.json";
        vm.writeFile(path, txs);

        console.log("Gnosis transaction written to:", path);
        console.log("Safe Factory:", safeFactory);
        console.log("New Safe Impl:", newSafeImpl);

        // Simulate execution
        executeGnosisTransactionBundle(path);
        console.log("Simulation passed");
    }
}
