// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { ChainConfig, Utils } from "../utils/Utils.sol";

/**
 * @title AaveV4TestActions
 * @notice Exercises the public LP lifecycle on the Aave v4 TEST instance deployed by
 *         DeployAaveV4TestInstance (addresses from deployments/<env>/10/aave-v4-test.json):
 *         supply weETH, enable it as collateral, and withdraw the whole position. Reserve ids
 *         are resolved on-chain by underlying, not from the manifest.
 * @dev Since the spoke upgrade to EtherFiSpokeInstanceDev, `borrow` reverts unless the position
 *      owner is an ether.fi Cash Safe, so this script no longer covers borrow/repay — exercise
 *      those through the LendGateway with a dev safe (see the lend dev-flows fork suite).
 *
 * Usage (simulate by dropping --broadcast):
 *   source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/AaveV4TestActions.s.sol:AaveV4TestActions \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 *
 * Optional env:
 *   SUPPLY_WEETH  weETH amount (18 decimals) to supply as collateral (default 0.002 weETH)
 */
contract AaveV4TestActions is Utils {
    IAaveV4Spoke spoke;
    IERC20 weeth;
    uint256 weethReserveId;
    address user;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/aave-v4-test.json"));
        spoke = IAaveV4Spoke(stdJson.readAddress(json, ".spoke"));
        ChainConfig memory cfg = getChainConfig(vm.toString(block.chainid));
        weethReserveId = _reserveIdOf(cfg.weETH);
        weeth = IERC20(cfg.weETH);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        user = vm.addr(privateKey);

        uint256 supplyWeeth = vm.envOr("SUPPLY_WEETH", uint256(0.002 ether));

        console.log("Spoke:", address(spoke));
        console.log("User: ", user);
        _logState("initial");

        require(weeth.balanceOf(user) >= supplyWeeth, "wallet lacks weETH for supply");

        vm.startBroadcast(privateKey);

        // 1. Supply weETH and enable it as collateral
        weeth.approve(address(spoke), supplyWeeth);
        (, uint256 supplied) = spoke.supply(weethReserveId, supplyWeeth, user);
        spoke.setUsingAsCollateral(weethReserveId, true, user);
        console.log("1. supplied weETH:", supplied);
        _logState("after supply");

        // 2. Withdraw the full weETH position (max signals a full withdrawal)
        (, uint256 withdrawn) = spoke.withdraw(weethReserveId, type(uint256).max, user);
        console.log("2. withdrew weETH:", withdrawn);

        vm.stopBroadcast();

        _logState("final");
    }

    function _reserveIdOf(address token) internal view returns (uint256) {
        uint256 count = spoke.getReserveCount();
        for (uint256 i; i < count; ++i) {
            if (spoke.getReserve(i).underlying == token) return i;
        }
        revert("reserve not listed on dev");
    }

    function _logState(string memory label) internal view {
        IAaveV4Spoke.UserAccountData memory data = spoke.getUserAccountData(user);
        console.log("--- state:", label);
        console.log("    wallet weETH:  ", weeth.balanceOf(user));
        console.log("    supplied weETH:", spoke.getUserSuppliedAssets(weethReserveId, user));
        if (data.healthFactor == type(uint256).max) console.log("    health factor:  max (no debt)");
        else console.log("    health factor (wad):", data.healthFactor);
    }
}
