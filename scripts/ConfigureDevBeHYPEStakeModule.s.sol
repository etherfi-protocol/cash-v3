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

    struct HypeFixtures {
        address l2BeHypeStaker;
        address whypeToken;
        address beHypeToken;
    }

    function _readHypeFixtures() internal view returns (HypeFixtures memory f) {
        string memory chainId = vm.toString(block.chainid);
        string memory fixturesFile = string.concat(
            vm.projectRoot(),
            string.concat("/deployments/", getEnv(), "/fixtures/fixtures.json")
        );
        string memory fixtures = vm.readFile(fixturesFile);

        f.l2BeHypeStaker = stdJson.readAddress(fixtures, string.concat(".", chainId, ".l2BeHypeStaker"));
        f.whypeToken = stdJson.readAddress(fixtures, string.concat(".", chainId, ".wHYPE"));
        f.beHypeToken = stdJson.readAddress(fixtures, string.concat(".", chainId, ".beHYPE"));

        require(f.l2BeHypeStaker != address(0), "l2BeHypeStaker not set in fixtures");
        require(f.whypeToken != address(0), "wHYPE not set in fixtures");
        require(f.beHypeToken != address(0), "beHYPE not set in fixtures");
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        string memory deployments = readDeploymentFile();
        HypeFixtures memory f = _readHypeFixtures();

        address dataProvider = stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider");
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        vm.startBroadcast(deployerPrivateKey);

        BeHYPEStakeModule beHypeStakeModule = new BeHYPEStakeModule(
            dataProvider,
            f.l2BeHypeStaker,
            f.whypeToken,
            f.beHypeToken,
            REFUND_GAS_LIMIT
        );
        console.log("BeHYPEStakeModule:", address(beHypeStakeModule));

        address[] memory modules = new address[](1);
        modules[0] = address(beHypeStakeModule);
        bool[] memory enable = new bool[](1);
        enable[0] = true;
        EtherFiDataProvider(dataProvider).configureDefaultModules(modules, enable);

        bytes32 adminRole = beHypeStakeModule.BEHYPE_STAKE_MODULE_ADMIN_ROLE();
        IRoleRegistry(roleRegistry).grantRole(adminRole, deployer);

        vm.stopBroadcast();

        console.log("Done. Add to deployments/dev/%s/deployments.json:", vm.toString(block.chainid));
        console.log('  "BeHYPEStakeModule": "%s"', address(beHypeStakeModule));
    }
}
