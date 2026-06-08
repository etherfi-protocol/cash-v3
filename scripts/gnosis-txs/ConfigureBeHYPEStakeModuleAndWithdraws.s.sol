// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "../../lib/forge-std/src/StdJson.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @notice Generates a Gnosis bundle (and simulates execution on the current fork) for the
 *         cash controller safe to:
 *           - whitelist the BeHYPEStakeModule as a default module on EtherFiDataProvider
 *           - grant BEHYPE_STAKE_MODULE_ADMIN_ROLE to the cash controller safe
 *
 *         wHYPE and beHYPE are already whitelisted as withdraw assets on CashModule
 *         (both dev and mainnet, verified on-chain).
 *
 *         Reads module/registry addresses from
 *         `deployments/{ENV}/{chainId}/deployments.json`.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/gnosis-txs/ConfigureBeHYPEStakeModuleAndWithdraws.s.sol:ConfigureBeHYPEStakeModuleAndWithdraws \
 *       --rpc-url $RPC
 */
contract ConfigureBeHYPEStakeModuleAndWithdraws is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        address roleRegistry = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "RoleRegistry")
        );
        address beHypeStakeModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "BeHYPEStakeModule")
        );

        address[] memory modules = new address[](1);
        modules[0] = beHypeStakeModule;

        bool[] memory whitelistModule = new bool[](1);
        whitelistModule[0] = true;

        bytes32 adminRole = BeHYPEStakeModule(beHypeStakeModule).BEHYPE_STAKE_MODULE_ADMIN_ROLE();

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory configureDefaultModule = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, whitelistModule));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), configureDefaultModule, "0", false)));

        string memory grantAdminRole = iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, adminRole, cashControllerSafe));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantAdminRole, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/ConfigureBeHYPEStakeModuleAndWithdraws.json";
        vm.writeFile(path, txs);
        executeGnosisTransactionBundle(path);
    }
}
