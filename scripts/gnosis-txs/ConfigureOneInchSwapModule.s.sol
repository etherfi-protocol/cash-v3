// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";

import {EtherFiDataProvider} from "../../src/data-provider/EtherFiDataProvider.sol";
import {GnosisHelpers} from "../utils/GnosisHelpers.sol";
import {Utils} from "../utils/Utils.sol";

/**
 * @title ConfigureOneInchSwapModule
 * @notice Generates a Gnosis Safe transaction to configure the OneInchSwapModule as a default module
 *
 *      ENV=mainnet ONE_INCH_MODULE=0x... forge script scripts/gnosis-txs/ConfigureOneInchSwapModule.s.sol --rpc-url <optimism_rpc>
 */
contract ConfigureOneInchSwapModule is GnosisHelpers, Utils {
    // Prod multisig (DATA_PROVIDER_ADMIN_ROLE holder)
    address constant multisig = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        address oneInchModule = vm.envAddress("ONE_INCH_MODULE");

        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        // Build Gnosis transaction: dataProvider.configureDefaultModules([module], [true])
        string memory txs = _getGnosisHeader(chainId, addressToHex(multisig));

        address[] memory modules = new address[](1);
        modules[0] = oneInchModule;

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        string memory configData = iToHex(
            abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, shouldWhitelist)
        );
        txs = string(abi.encodePacked(
            txs,
            _getGnosisTransaction(addressToHex(dataProvider), configData, "0", true)
        ));

        vm.createDir("./output", true);
        string memory path = "./output/ConfigureOneInchSwapModule.json";
        vm.writeFile(path, txs);

        console.log("Gnosis transaction written to:", path);
        console.log("DataProvider:", dataProvider);
        console.log("OneInchSwapModule:", oneInchModule);

        // Simulate execution
        executeGnosisTransactionBundle(path);
        console.log("Simulation passed");
    }
}
