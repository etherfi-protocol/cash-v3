// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @notice Deploys BeHYPEStakeModule for the current chain. Reads `wHYPE`, `beHYPE`,
 *         and `l2BeHypeStaker` from `deployments/{ENV}/fixtures/fixtures.json` keyed
 *         by `block.chainid`, and `EtherFiDataProvider` from the chain deployments file.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/gnosis-txs/DeployBeHYPEStakeModule.s.sol:DeployBeHYPEStakeModule \
 *       --rpc-url $RPC --broadcast
 *
 * After deploy, record the address under `addresses.BeHYPEStakeModule` in
 * `deployments/{ENV}/{chainId}/deployments.json` before running the configure script.
 */
contract DeployBeHYPEStakeModule is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    uint32 refundGasLimit = 5_000;

    BeHYPEStakeModule public beHypeStakeModule;

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        string memory fixturesFile = string.concat(
            vm.projectRoot(),
            string.concat("/deployments/", getEnv(), "/fixtures/fixtures.json")
        );
        string memory fixtures = vm.readFile(fixturesFile);

        address l2BeHypeStaker = stdJson.readAddress(
            fixtures,
            string.concat(".", chainId, ".l2BeHypeStaker")
        );
        address whypeToken = stdJson.readAddress(
            fixtures,
            string.concat(".", chainId, ".wHYPE")
        );
        address beHypeToken = stdJson.readAddress(
            fixtures,
            string.concat(".", chainId, ".beHYPE")
        );

        require(l2BeHypeStaker != address(0), "DeployBeHYPEStakeModule: l2BeHypeStaker not set in fixtures");
        require(whypeToken != address(0), "DeployBeHYPEStakeModule: wHYPE not set in fixtures");
        require(beHypeToken != address(0), "DeployBeHYPEStakeModule: beHYPE not set in fixtures");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );

        vm.startBroadcast(deployerPrivateKey);

        beHypeStakeModule = new BeHYPEStakeModule(
            dataProvider,
            l2BeHypeStaker,
            whypeToken,
            beHypeToken,
            refundGasLimit
        );

        vm.stopBroadcast();
    }
}

