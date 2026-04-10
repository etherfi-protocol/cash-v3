// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { AaveV3Module, ModuleBase, ModuleCheckBalance } from "../../../../src/modules/aave-v3/AaveV3Module.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, IDebtManager } from "../../SafeTestSetup.t.sol";
import { ChainConfig } from "../../../utils/Utils.sol";

contract AaveV3TestSetup is SafeTestSetup {
    using MessageHashUtils for bytes32;

    AaveV3Module public aaveV3Module;

    function setUp() public virtual override {
        ChainConfig memory _cc = getChainConfig();
        vm.skip(_cc.aaveV3Pool == address(0));
        super.setUp();

        aaveV3Module = new AaveV3Module(chainConfig.aaveV3Pool, chainConfig.aaveV3IncentivesManager, chainConfig.aaveWrappedTokenGateway, address(dataProvider));

        address[] memory modules = new address[](1);
        modules[0] = address(aaveV3Module);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.prank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);

        bytes[] memory setupData = new bytes[](1);

        _configureModules(modules, shouldWhitelist, setupData);
    }
}