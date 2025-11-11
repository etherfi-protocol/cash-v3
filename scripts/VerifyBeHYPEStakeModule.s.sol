// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {BeHYPEStakeModule} from "../src/modules/hype/BeHYPEStakeModule.sol";
import {ContractCodeChecker} from "./utils/ContractCodeChecker.sol";

contract VerifyBeHYPEStakeModule is Script, ContractCodeChecker {
    address internal constant DEPLOYED_MODULE = 0x51142BC586A7b4cbECDCD5B0C68064714B322CBC;
    string internal constant DEFAULT_SCROLL_RPC = "https://rpc.scroll.io";

    function run() public {
        string memory scrollRpc = vm.envOr("SCROLL_RPC", DEFAULT_SCROLL_RPC);
        vm.createSelectFork(scrollRpc);

        BeHYPEStakeModule deployedModule = BeHYPEStakeModule(DEPLOYED_MODULE);

        address dataProvider = address(deployedModule.etherFiDataProvider());
        address staker = address(deployedModule.staker());
        address whype = deployedModule.whype();
        address beHYPE = deployedModule.beHYPE();
        uint32 refundGasLimit = deployedModule.getRefundGasLimit();

        console2.log("Rebuilding BeHYPEStakeModule with on-chain constructor parameters...");
        console2.log("  etherFiDataProvider", dataProvider);
        console2.log("  staker", staker);
        console2.log("  whype", whype);
        console2.log("  beHYPE", beHYPE);
        console2.log("  refundGasLimit", uint256(refundGasLimit));

        BeHYPEStakeModule localModule = new BeHYPEStakeModule(
            dataProvider,
            staker,
            whype,
            beHYPE,
            refundGasLimit
        );

        console2.log("Verifying bytecode between deployed and locally rebuilt contracts...");
        verifyContractByteCodeMatch(DEPLOYED_MODULE, address(localModule));
    }
}

