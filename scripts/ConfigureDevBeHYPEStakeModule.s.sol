// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";

import {BeHYPEStakeModule} from "../src/modules/hype/BeHYPEStakeModule.sol";
import {EtherFiDataProvider} from "../src/data-provider/EtherFiDataProvider.sol";
import {IRoleRegistry} from "../src/interfaces/IRoleRegistry.sol";
import {Utils} from "./utils/Utils.sol";

/**
 * @title ConfigureDevBeHYPEStakeModule
 * @notice Deploys and configures the BeHYPEStakeModule on the dev environment.
 *         Reads wHYPE, beHYPE, and l2BeHypeStaker from dev fixtures.
 *         Broadcasts directly (no Gnosis bundle required for dev).
 *
 * ENV=dev forge script scripts/ConfigureDevBeHYPEStakeModule.s.sol:ConfigureDevBeHYPEStakeModule \
 *     --rpc-url $RPC --broadcast -vvvv
 */
contract ConfigureDevBeHYPEStakeModule is Utils {
    uint32 constant REFUND_GAS_LIMIT = 5_000;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        string memory fixturesFile = string.concat(
            vm.projectRoot(),
            string.concat("/deployments/", getEnv(), "/fixtures/fixtures.json")
        );
        string memory fixtures = vm.readFile(fixturesFile);

        address l2BeHypeStaker = stdJson.readAddress(fixtures, string.concat(".", chainId, ".l2BeHypeStaker"));
        address whypeToken = stdJson.readAddress(fixtures, string.concat(".", chainId, ".wHYPE"));
        address beHypeToken = stdJson.readAddress(fixtures, string.concat(".", chainId, ".beHYPE"));

        require(l2BeHypeStaker != address(0), "l2BeHypeStaker not set in fixtures");
        require(whypeToken != address(0), "wHYPE not set in fixtures");
        require(beHypeToken != address(0), "beHYPE not set in fixtures");

        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy BeHYPEStakeModule
        console.log("Deploying BeHYPEStakeModule...");
        BeHYPEStakeModule beHypeStakeModule = new BeHYPEStakeModule(
            dataProvider,
            l2BeHypeStaker,
            whypeToken,
            beHypeToken,
            REFUND_GAS_LIMIT
        );
        console.log("  BeHYPEStakeModule:", address(beHypeStakeModule));

        // 2. Whitelist as default module
        console.log("Whitelisting BeHYPEStakeModule as default module...");
        address[] memory modules = new address[](1);
        modules[0] = address(beHypeStakeModule);

        bool[] memory enable = new bool[](1);
        enable[0] = true;

        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, enable);

        // 3. Grant BEHYPE_STAKE_MODULE_ADMIN_ROLE to deployer
        console.log("Granting BEHYPE_STAKE_MODULE_ADMIN_ROLE to deployer...");
        bytes32 adminRole = beHypeStakeModule.BEHYPE_STAKE_MODULE_ADMIN_ROLE();
        IRoleRegistry(roleRegistry).grantRole(adminRole, deployer);

        vm.stopBroadcast();

        console.log("Done. Add to deployments/dev/%s/deployments.json:", chainId);
        console.log('  "BeHYPEStakeModule": "%s"', address(beHypeStakeModule));
    }
}
