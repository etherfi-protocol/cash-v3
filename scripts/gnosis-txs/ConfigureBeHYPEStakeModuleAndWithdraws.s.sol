// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "../../lib/forge-std/src/StdJson.sol";
import {StdCheats} from "../../lib/forge-std/src/StdCheats.sol";

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract ConfigureBeHYPEStakeModuleAndWithdraws is GnosisHelpers, Utils, StdCheats {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address whypeToken = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address beHypeToken = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;

    function run() public {
  
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();
        address dataProvider = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "EtherFiDataProvider")
        );
        address cashModule = stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "CashModule")
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

        address[] memory withdrawTokens = new address[](2);
        withdrawTokens[0] = whypeToken;
        withdrawTokens[1] = beHypeToken;

        bool[] memory withdrawWhitelist = new bool[](2);
        withdrawWhitelist[0] = true;
        withdrawWhitelist[1] = true;

        bytes32 adminRole = BeHYPEStakeModule(beHypeStakeModule).BEHYPE_STAKE_MODULE_ADMIN_ROLE();

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        string memory configureDefaultModule = iToHex(abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, whitelistModule));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(dataProvider), configureDefaultModule, "0", false)));

        string memory configureWithdrawAssets = iToHex(abi.encodeWithSelector(CashModuleSetters.configureWithdrawAssets.selector, withdrawTokens, withdrawWhitelist));
        txs = string(abi.encodePacked(txs,_getGnosisTransaction(addressToHex(cashModule), configureWithdrawAssets, "0", false)));

        string memory grantAdminRole = iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, adminRole, cashControllerSafe));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantAdminRole, "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/ConfigureBeHYPEStakeModuleAndWithdraws.json";
        vm.writeFile(path, txs);
        executeGnosisTransactionBundle(path);
    }
}
