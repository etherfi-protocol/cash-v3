// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

interface ITopUpDest {
    function withdraw(address token, uint256 amount) external;
    function getDeposit(address token) external view returns (uint256);
}

/**
 * @notice Generates the 3CP JSON to withdraw excess USDT liquidity from `TopUpDest`
 *         on Optimism back to the Cash Controller Safe (the RoleRegistry owner).
 *
 *         `TopUpDest.withdraw(token, amount)` is gated by `onlyRoleRegistryOwner()`
 *         and hardcodes the recipient to `msg.sender`, so the funds land in the Safe
 *         that signs this transaction. Single call, single Safe, single chain,
 *         operation=0 (direct CALL, no MultiSend).
 *
 * Usage:
 *   source .env && forge script scripts/gnosis-txs/WithdrawTopUpDestUSDT.s.sol --rpc-url $OPTIMISM_RPC
 */
contract WithdrawTopUpDestUSDT is GnosisHelpers, Utils, Test {
    // Optimism USDT (6 decimals) — deployments/mainnet/fixtures/fixtures.json ["10"].usdt
    address constant USDT_OP = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;

    // 1,000,000 USDT (6 decimals)
    uint256 constant WITHDRAW_AMOUNT = 1_000_000e6;

    function run() public {
        require(block.chainid == 10, "This 3CP targets Optimism (chainId 10) only");

        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        address topUpDest = stdJson.readAddress(deployments, ".addresses.TopUpDest");
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        require(topUpDest != address(0), "TopUpDest not found");
        require(roleRegistry != address(0), "RoleRegistry not found");

        // withdraw() sends to msg.sender, which must be the RoleRegistry owner (the Safe).
        address safe = IRoleRegistry(roleRegistry).owner();
        require(safe != address(0), "RoleRegistry owner is zero");

        // Pre-flight guards mirror the on-chain checks in TopUpDest.withdraw / _transfer.
        uint256 recordedDeposit = ITopUpDest(topUpDest).getDeposit(USDT_OP);
        uint256 liveBalance = IERC20(USDT_OP).balanceOf(topUpDest);
        require(recordedDeposit >= WITHDRAW_AMOUNT, "withdraw > recorded deposit");
        require(liveBalance >= WITHDRAW_AMOUNT, "withdraw > live balance");

        // Build the single-transaction 3CP bundle.
        string memory txs = _getGnosisHeader(chainId, addressToHex(safe));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(topUpDest),
            iToHex(abi.encodeWithSelector(ITopUpDest.withdraw.selector, USDT_OP, WITHDRAW_AMOUNT)),
            "0", true
        )));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/WithdrawTopUpDestUSDT-", chainId, ".json");
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        // Fork-simulate against live Optimism state (prank = Safe).
        uint256 safeBalBefore = IERC20(USDT_OP).balanceOf(safe);
        uint256 depositBefore = ITopUpDest(topUpDest).getDeposit(USDT_OP);

        executeGnosisTransactionBundle(path);

        uint256 safeBalAfter = IERC20(USDT_OP).balanceOf(safe);
        uint256 depositAfter = ITopUpDest(topUpDest).getDeposit(USDT_OP);

        assertEq(safeBalAfter - safeBalBefore, WITHDRAW_AMOUNT, "Safe did not receive withdrawn USDT");
        assertEq(depositBefore - depositAfter, WITHDRAW_AMOUNT, "deposit accounting not decremented");

        console.log("Safe:                 %s", safe);
        console.log("TopUpDest:            %s", topUpDest);
        console.log("USDT withdrawn:       %s", WITHDRAW_AMOUNT);
        console.log("Safe USDT before:     %s", safeBalBefore);
        console.log("Safe USDT after:      %s", safeBalAfter);
        console.log("Recorded deposit now: %s", depositAfter);
        console.log("Simulation passed");
    }
}
