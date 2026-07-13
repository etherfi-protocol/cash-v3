// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title AaveV4TestActions
 * @notice Exercises the full user lifecycle on the Aave v4 TEST instance deployed by
 *         DeployAaveV4TestInstance (addresses from deployments/<env>/10/aave-v4-test.json):
 *         supply weETH, enable it as collateral, borrow USDC, repay the debt in full, and
 *         withdraw the whole position. If the USDC reserve lacks the liquidity to cover the
 *         borrow, the wallet supplies the shortfall first and withdraws it again at the end,
 *         so a successful run leaves no residue besides interest dust.
 *
 * Usage (simulate by dropping --broadcast):
 *   source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/AaveV4TestActions.s.sol:AaveV4TestActions \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 *
 * Optional env:
 *   SUPPLY_WEETH  weETH amount (18 decimals) to supply as collateral (default 0.002 weETH)
 *   BORROW_USDC   USDC amount (6 decimals) to borrow (default 1 USDC)
 */
contract AaveV4TestActions is Utils {
    IAaveV4Spoke spoke;
    IERC20 weeth;
    IERC20 usdc;
    uint256 weethReserveId;
    uint256 usdcReserveId;
    address user;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/aave-v4-test.json"));
        spoke = IAaveV4Spoke(stdJson.readAddress(json, ".spoke"));
        weethReserveId = stdJson.readUint(json, ".weethReserveId");
        usdcReserveId = stdJson.readUint(json, ".usdcReserveId");
        weeth = IERC20(spoke.getReserve(weethReserveId).underlying);
        usdc = IERC20(spoke.getReserve(usdcReserveId).underlying);

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        user = vm.addr(privateKey);

        uint256 supplyWeeth = vm.envOr("SUPPLY_WEETH", uint256(0.002 ether));
        uint256 borrowUsdc = vm.envOr("BORROW_USDC", uint256(1e6));

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

        // 2. Make sure the USDC reserve can cover the borrow, seeding the shortfall from the wallet
        uint256 available = spoke.getReserveSuppliedAssets(usdcReserveId) - spoke.getReserveTotalDebt(usdcReserveId);
        uint256 seeded = 0;
        if (available < borrowUsdc) {
            seeded = borrowUsdc - available;
            require(usdc.balanceOf(user) >= seeded, "wallet lacks USDC to seed borrow liquidity");
            usdc.approve(address(spoke), seeded);
            spoke.supply(usdcReserveId, seeded, user);
            console.log("2. seeded USDC liquidity:", seeded);
        }

        // 3. Borrow USDC against the weETH collateral
        (, uint256 borrowed) = spoke.borrow(usdcReserveId, borrowUsdc, user);
        console.log("3. borrowed USDC:", borrowed);
        _logState("after borrow");

        // 4. Repay in full; the approval carries 1% headroom for interest accrued between the
        //    approve and repay transactions landing, and is cleared afterwards
        uint256 debt = spoke.getUserTotalDebt(usdcReserveId, user);
        require(usdc.balanceOf(user) >= debt, "wallet lacks USDC to repay");
        usdc.approve(address(spoke), (debt * 101) / 100 + 1);
        (, uint256 repaid) = spoke.repay(usdcReserveId, type(uint256).max, user);
        usdc.approve(address(spoke), 0);
        console.log("4. repaid USDC:", repaid);
        _logState("after repay");

        // 5. Withdraw the full weETH position (max signals a full withdrawal)
        (, uint256 withdrawn) = spoke.withdraw(weethReserveId, type(uint256).max, user);
        console.log("5. withdrew weETH:", withdrawn);

        // 6. Pull back any liquidity seeded in step 2
        if (seeded > 0) {
            (, uint256 unseeded) = spoke.withdraw(usdcReserveId, type(uint256).max, user);
            console.log("6. withdrew seeded USDC:", unseeded);
        }

        vm.stopBroadcast();

        _logState("final");
    }

    function _logState(string memory label) internal view {
        IAaveV4Spoke.UserAccountData memory data = spoke.getUserAccountData(user);
        console.log("--- state:", label);
        console.log("    wallet weETH:  ", weeth.balanceOf(user));
        console.log("    wallet USDC:   ", usdc.balanceOf(user));
        console.log("    supplied weETH:", spoke.getUserSuppliedAssets(weethReserveId, user));
        console.log("    supplied USDC: ", spoke.getUserSuppliedAssets(usdcReserveId, user));
        console.log("    USDC debt:     ", spoke.getUserTotalDebt(usdcReserveId, user));
        if (data.healthFactor == type(uint256).max) console.log("    health factor:  max (no debt)");
        else console.log("    health factor (wad):", data.healthFactor);
    }
}
