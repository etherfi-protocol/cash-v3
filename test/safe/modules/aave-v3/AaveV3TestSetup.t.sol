// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";

import { AaveV3Module, ModuleBase, ModuleCheckBalance } from "../../../../src/modules/aave-v3/AaveV3Module.sol";
import { ArrayDeDupLib, EtherFiDataProvider, EtherFiSafe, EtherFiSafeErrors, SafeTestSetup, IDebtManager } from "../../SafeTestSetup.t.sol";

contract AaveV3TestSetup is SafeTestSetup {
    using MessageHashUtils for bytes32;

    AaveV3Module public aaveV3Module;
    address public aaveV3PoolScroll = 0x11fCfe756c05AD438e312a7fd934381537D3cFfe;
    address public aaveV3IncentivesManagerScroll = 0xa3f3100C4f1D0624DB9DB97b40C13885Ce297799;
    address public aaveWrappedTokenGateway = 0xE79Ca44408Dae5a57eA2a9594532f1E84d2edAa4;
    address ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public virtual override {
        super.setUp();

        aaveV3Module = new AaveV3Module(aaveV3PoolScroll, aaveV3IncentivesManagerScroll, address(aaveWrappedTokenGateway), address(dataProvider));

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