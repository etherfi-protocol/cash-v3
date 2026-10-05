// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

interface ITimelock {
    function scheduleBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt, uint256 delay) external;
    function executeBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads, bytes32 predecessor, bytes32 salt) external payable;
    function getMinDelay() external view returns (uint256);
}

/**
 * @notice SUPERSEDED — do not sign the bundles this writes.
 *
 *         The drawdown was folded into StockWithdrawGrantAndTopUpDrawdownOP3CP.s.sol, which
 *         carries these same six calls plus the StockWithdrawModule admin-role grant as ONE
 *         atomic timelock batch. Keeping both signable is dangerous: after the combined batch
 *         executes, deposits[USDC] still sits at 199,000e6, so a stale execute of THIS bundle's
 *         USDC leg would succeed and pull a second, unintended 100k USDC. (The USDT and beHYPE
 *         legs would revert on the deposits ceiling.) Delete this file once the combined batch
 *         is signed.
 *
 * @notice Pulls capital out of TopUpDest on Optimism and forwards it to the ops wallet.
 *         - 400k USDT
 *         - 100k USDC
 *         - 829 beHYPE (the full withdrawable balance)
 *
 * @dev TopUpDest.withdraw() is onlyRoleRegistryOwner, and the RoleRegistry owner is now the
 *      EtherFiTimelock (0x9106cD76…) — NOT the OperatingSafe. So the batch must run *as the
 *      timelock*: the safe schedules it, waits out the 8h delay, then executes it.
 *
 *      withdraw() pays msg.sender, so during executeBatch the tokens land in the timelock
 *      itself; calls 4-6 then transfer them out from the timelock's own context. All six run
 *      inside one executeBatch, so the funds never rest anywhere between calls.
 *
 *      Produces two Gnosis JSONs: the schedule tx (nonce N) and the execute tx (nonce N+1).
 */
contract WithdrawTopUpDestFundsOP3CP is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address destAddress = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;
    address etherFiTimelock = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;

    bytes32 constant PREDECESSOR = bytes32(0);
    bytes32 constant SALT = bytes32(0);

    uint256 constant USDT_AMOUNT = 400_000e6;
    uint256 constant USDC_AMOUNT = 100_000e6;

    // TopUpDest holds ~834.35 beHYPE but withdraw() is capped at deposits[beHYPE] = 829e18,
    // so 829 is both the round number and the maximum withdrawable. The ~5.35 remainder is
    // only reachable after a further deposit() bumps the accounting back up.
    uint256 constant BEHYPE_AMOUNT = 829e18;

    address topUpDest;
    address usdc;
    address usdt;
    address beHYPE;

    function _loadAddresses() internal {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();
        string memory fixtures = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/fixtures/fixtures.json"));

        topUpDest = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "TopUpDest"));
        usdc = stdJson.readAddress(fixtures, string.concat(".", chainId, ".", "usdc"));
        usdt = stdJson.readAddress(fixtures, string.concat(".", chainId, ".", "usdt"));
        beHYPE = stdJson.readAddress(fixtures, string.concat(".", chainId, ".", "beHYPE"));
    }

    function _writeBundle(string memory path, bytes memory data) internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(cashControllerSafe));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(etherFiTimelock), iToHex(data), "0", true)));
        vm.writeFile(path, txs);
    }

    function run() public {
        _loadAddresses();
        string memory chainId = vm.toString(block.chainid);

        _logState(topUpDest, "USDT", usdt, USDT_AMOUNT);
        _logState(topUpDest, "USDC", usdc, USDC_AMOUNT);
        _logState(topUpDest, "beHYPE", beHYPE, BEHYPE_AMOUNT);

        // The batch the timelock will run: 3 withdrawals into the timelock, then 3 transfers out.
        address[] memory targets = new address[](6);
        uint256[] memory values = new uint256[](6);
        bytes[] memory payloads = new bytes[](6);

        (targets[0], payloads[0]) = (topUpDest, abi.encodeWithSelector(TopUpDest.withdraw.selector, usdt, USDT_AMOUNT));
        (targets[1], payloads[1]) = (topUpDest, abi.encodeWithSelector(TopUpDest.withdraw.selector, usdc, USDC_AMOUNT));
        (targets[2], payloads[2]) = (topUpDest, abi.encodeWithSelector(TopUpDest.withdraw.selector, beHYPE, BEHYPE_AMOUNT));
        (targets[3], payloads[3]) = (usdt, abi.encodeWithSelector(IERC20.transfer.selector, destAddress, USDT_AMOUNT));
        (targets[4], payloads[4]) = (usdc, abi.encodeWithSelector(IERC20.transfer.selector, destAddress, USDC_AMOUNT));
        (targets[5], payloads[5]) = (beHYPE, abi.encodeWithSelector(IERC20.transfer.selector, destAddress, BEHYPE_AMOUNT));

        uint256 delay = ITimelock(etherFiTimelock).getMinDelay();
        emit log_named_uint("timelock minDelay (s)", delay);

        vm.createDir("./output", true);

        string memory schedulePath = string.concat("./output/WithdrawTopUpDestFundsOP3CP-schedule-", chainId, ".json");
        _writeBundle(schedulePath, abi.encodeWithSelector(ITimelock.scheduleBatch.selector, targets, values, payloads, PREDECESSOR, SALT, delay));

        string memory executePath = string.concat("./output/WithdrawTopUpDestFundsOP3CP-execute-", chainId, ".json");
        _writeBundle(executePath, abi.encodeWithSelector(ITimelock.executeBatch.selector, targets, values, payloads, PREDECESSOR, SALT));

        uint256 destUsdtBefore = IERC20(usdt).balanceOf(destAddress);
        uint256 destUsdcBefore = IERC20(usdc).balanceOf(destAddress);
        uint256 destBeHypeBefore = IERC20(beHYPE).balanceOf(destAddress);

        // Simulate the full lifecycle: schedule, wait out the delay, execute.
        executeGnosisTransactionBundle(schedulePath);
        vm.warp(block.timestamp + delay + 1);
        executeGnosisTransactionBundle(executePath);

        assertEq(IERC20(usdt).balanceOf(destAddress) - destUsdtBefore, USDT_AMOUNT, "USDT not received");
        assertEq(IERC20(usdc).balanceOf(destAddress) - destUsdcBefore, USDC_AMOUNT, "USDC not received");
        assertEq(IERC20(beHYPE).balanceOf(destAddress) - destBeHypeBefore, BEHYPE_AMOUNT, "beHYPE not received");
        assertEq(IERC20(usdt).balanceOf(etherFiTimelock), 0, "USDT stranded in timelock");
        assertEq(IERC20(usdc).balanceOf(etherFiTimelock), 0, "USDC stranded in timelock");
        assertEq(IERC20(beHYPE).balanceOf(etherFiTimelock), 0, "beHYPE stranded in timelock");
    }

    /// @dev Logs the live state and asserts both of withdraw()'s constraints hold for the hardcoded amount
    function _logState(address dest, string memory name, address token, uint256 amount) internal {
        uint256 balance = IERC20(token).balanceOf(dest);
        uint256 deposits = TopUpDest(payable(dest)).getDeposit(token);

        emit log_named_string("token", name);
        emit log_named_uint("  balance    ", balance);
        emit log_named_uint("  deposits   ", deposits);
        emit log_named_uint("  withdrawing", amount);

        require(amount > 0, string.concat(name, ": amount is zero"));
        require(deposits >= amount, string.concat(name, ": amount exceeds deposits accounting"));
        require(balance >= amount, string.concat(name, ": amount exceeds TopUpDest balance"));
    }
}
