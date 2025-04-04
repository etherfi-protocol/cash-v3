// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { ILayerZeroTeller } from "../src/interfaces/ILayerZeroTeller.sol";
import { Utils } from "./utils/Utils.sol";
import { IDebtManager } from "../src/interfaces/IDebtManager.sol";

contract SupportBorrowToken is Utils {
    IERC20 public liquidUsd = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    IERC20 public eUsd = IERC20(0x939778D83b46B456224A33Fb59630B11DEC56663);

    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(privateKey);
        
        string memory deployments = readDeploymentFile();

        IDebtManager debtManager = IDebtManager(stdJson.readAddress(
            deployments,
            string.concat(".", "addresses", ".", "DebtManager")
        ));

        debtManager.supportBorrowToken(address(liquidUsd), 1, type(uint128).max);
        debtManager.supportBorrowToken(address(eUsd), 1, type(uint128).max);

        vm.stopBroadcast();
    }
}
