// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IBoringOnChainQueue } from "../../src/interfaces/IBoringOnChainQueue.sol";
import { IEtherFiSafe } from "../../src/interfaces/IEtherFiSafe.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title SetEusdWithdrawQueueOP3CP
 * @notice Lets Cash safes on Optimism withdraw eUSD to USDC through the eUSD BoringQueue, the same way they
 *         already withdraw eBTC and sETHFI.
 *
 *         eUSD and its teller are already on the prod EtherFiLiquidModuleWithReferrer (deposits work), but the
 *         module has no withdraw queue for eUSD, so `withdraw` reverts with LiquidWithdrawConfigNotSet. This
 *         sets it:
 *
 *           EtherFiLiquidModuleWithReferrer.setLiquidAssetWithdrawQueue(eUSD, eUSD BoringQueue)
 *
 *         The setter is gated to the RoleRegistry owner, which is the 2-day upgrade timelock, so it ships as
 *         two bundles from the governance Safe:
 *           schedule  upgradeTimelock.schedule
 *           execute   upgradeTimelock.execute (not before 2 days after the schedule executes)
 *
 *         No broadcast: writes Safe Transaction Builder JSONs to ./output and simulates them on the fork, then
 *         replays the exact calls the module makes from a real Cash safe that holds eUSD (approve + request on
 *         the queue) to show a safe can enter the queue.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/gnosis-txs/SetEusdWithdrawQueueOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 *   TEST_SAFE=<cash safe holding eUSD> overrides the safe used for the withdrawal simulation.
 */
contract SetEusdWithdrawQueueOP3CP is Utils, GnosisHelpers {
    using stdJson for string;

    address internal constant GOVERNANCE_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    uint256 internal constant UPGRADE_DELAY = 2 days;

    address internal constant EUSD = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address internal constant EUSD_TELLER = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;
    address internal constant EUSD_QUEUE = 0xecAAd9C5A5988465Be116C3891B2EEf96Cb48C96;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    /// @dev Prod Cash safe holding eUSD on Optimism, used only to simulate a withdrawal request
    address internal constant DEFAULT_TEST_SAFE = 0x4C521EF6579364B41f2FD85bCB47e7Bee64B3Dc5;

    bytes32 internal constant TL_PREDECESSOR = bytes32(0);
    bytes32 internal constant TL_SALT = keccak256("SetEusdWithdrawQueue.OP.v1");

    EtherFiDataProvider internal dataProvider;
    RoleRegistry internal roleRegistry;
    EtherFiLiquidModule internal module;

    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");
        console.log("Fork block:", block.number);
        uint256 forkTimestamp = block.timestamp;

        string memory deployments = readDeploymentFile();
        dataProvider = EtherFiDataProvider(deployments.readAddress(".addresses.EtherFiDataProvider"));
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        module = EtherFiLiquidModule(payable(deployments.readAddress(".addresses.EtherFiLiquidModuleWithReferrer")));

        _checkPreconditions();

        bytes memory call = abi.encodeCall(EtherFiLiquidModule.setLiquidAssetWithdrawQueue, (EUSD, EUSD_QUEUE));
        TimelockController tl = TimelockController(payable(UPGRADE_TIMELOCK));
        bytes32 id = tl.hashOperation(address(module), 0, call, TL_PREDECESSOR, TL_SALT);
        require(!tl.isOperation(id), "operation already scheduled");

        string memory schedulePath = "./output/SetEusdWithdrawQueueOP-10-schedule.json";
        string memory executePath = "./output/SetEusdWithdrawQueueOP-10-execute.json";
        _writeBundle(schedulePath, abi.encodeCall(TimelockController.schedule, (address(module), 0, call, TL_PREDECESSOR, TL_SALT, UPGRADE_DELAY)));
        _writeBundle(executePath, abi.encodeCall(TimelockController.execute, (address(module), 0, call, TL_PREDECESSOR, TL_SALT)));

        // The governance Safe cannot set the queue directly; only the timelock can
        vm.prank(GOVERNANCE_SAFE);
        (bool ok,) = address(module).call(call);
        require(!ok, "governance Safe set the queue directly");

        console.log("=== Simulating schedule (governance Safe) ===");
        executeGnosisTransactionBundle(schedulePath);
        require(tl.isOperationPending(id) && !tl.isOperationReady(id), "operation not pending after schedule");

        vm.warp(block.timestamp + UPGRADE_DELAY - 1);
        vm.prank(GOVERNANCE_SAFE);
        (ok,) = UPGRADE_TIMELOCK.call(abi.encodeCall(TimelockController.execute, (address(module), 0, call, TL_PREDECESSOR, TL_SALT)));
        require(!ok, "execute succeeded before 2 days");

        vm.warp(block.timestamp + 1);
        require(tl.isOperationReady(id), "operation not ready after 2 days");

        console.log("=== Simulating execute (governance Safe) ===");
        executeGnosisTransactionBundle(executePath);
        require(tl.isOperationDone(id), "operation not done after execute");

        _checkEndState();

        // Back to the fork's real time: 2 days ahead, every price feed the safe's spend checks read is stale
        vm.warp(forkTimestamp);
        _simulateSafeWithdrawRequest(vm.envOr("TEST_SAFE", DEFAULT_TEST_SAFE));

        console.log("");
        console.log("  [OK] eUSD withdraw queue set on EtherFiLiquidModuleWithReferrer:", address(module));
        console.log("Timelock operation id:");
        console.logBytes32(id);
    }

    function _checkPreconditions() internal view {
        require(roleRegistry.owner() == UPGRADE_TIMELOCK, "RoleRegistry owner is not the upgrade timelock");
        require(keccak256(UPGRADE_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local build");
        EtherFiTimelock tl = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
        require(tl.getMinDelay() == UPGRADE_DELAY, "timelock: unexpected delay");
        require(tl.hasRole(tl.PROPOSER_ROLE(), GOVERNANCE_SAFE) && tl.hasRole(tl.EXECUTOR_ROLE(), GOVERNANCE_SAFE), "governance Safe is not proposer and executor");

        require(address(module.etherFiDataProvider()) == address(dataProvider), "module bound to another data provider");
        require(dataProvider.isWhitelistedModule(address(module)), "module is not whitelisted");
        require(address(module.liquidAssetToTeller(EUSD)) == EUSD_TELLER, "eUSD teller on the module changed");
        require(module.liquidWithdrawQueue(EUSD) == address(0), "eUSD queue already set");

        IBoringOnChainQueue queue = IBoringOnChainQueue(EUSD_QUEUE);
        require(address(queue.boringVault()) == EUSD, "queue is not the eUSD queue");
        IBoringOnChainQueue.WithdrawAsset memory wa = queue.withdrawAssets(USDC);
        require(wa.allowWithdraws, "eUSD queue does not allow USDC withdrawals");
        console.log("eUSD queue USDC config: maturity (s), min deadline (s), max discount (bps):", wa.secondsToMaturity, wa.minimumSecondsToDeadline, wa.maxDiscount);
    }

    function _checkEndState() internal view {
        require(module.liquidWithdrawQueue(EUSD) == EUSD_QUEUE, "eUSD queue not set");
        require(module.getLiquidAssetWithdrawQueue(EUSD) == EUSD_QUEUE, "getter disagrees");
        require(address(module.liquidAssetToTeller(EUSD)) == EUSD_TELLER, "eUSD teller changed");
        require(roleRegistry.owner() == UPGRADE_TIMELOCK, "RoleRegistry owner changed");
    }

    /// @dev Replays what EtherFiLiquidModule._withdraw does after its signature check: from the safe, approve the
    ///      queue and request USDC. Proves a Cash safe's eUSD can enter the queue; it does not prove a solver pays out.
    function _simulateSafeWithdrawRequest(address safe) internal {
        require(dataProvider.isEtherFiSafe(safe), "TEST_SAFE is not a Cash safe");
        uint256 balance = IERC20(EUSD).balanceOf(safe);
        require(balance > 0, "TEST_SAFE holds no eUSD");

        IBoringOnChainQueue queue = IBoringOnChainQueue(EUSD_QUEUE);
        IBoringOnChainQueue.WithdrawAsset memory wa = queue.withdrawAssets(USDC);
        uint128 shares = uint128(balance / 10);
        if (shares < wa.minimumShares) shares = uint128(balance);
        uint16 discount = wa.minDiscount;
        uint24 deadline = wa.minimumSecondsToDeadline;
        uint128 usdcOut = queue.previewAssetsOut(USDC, shares, discount);

        address[] memory to = new address[](2);
        bytes[] memory data = new bytes[](2);
        to[0] = EUSD;
        data[0] = abi.encodeCall(IERC20.approve, (EUSD_QUEUE, shares));
        to[1] = EUSD_QUEUE;
        data[1] = abi.encodeCall(IBoringOnChainQueue.requestOnChainWithdraw, (USDC, shares, discount, deadline));

        uint256 queueBefore = IERC20(EUSD).balanceOf(EUSD_QUEUE);
        vm.prank(address(module));
        IEtherFiSafe(safe).execTransactionFromModule(to, new uint256[](2), data);

        require(IERC20(EUSD).balanceOf(safe) == balance - shares, "safe eUSD not debited");
        require(IERC20(EUSD).balanceOf(EUSD_QUEUE) == queueBefore + shares, "queue did not receive the shares");
        console.log("=== Simulated Cash safe withdrawal request ===");
        console.log("  safe:", safe);
        console.log("  eUSD shares queued:", shares);
        console.log("  USDC quoted out (6 dp):", usdcOut);
    }

    function _writeBundle(string memory path, bytes memory data) internal {
        string memory header = _getGnosisHeader(vm.toString(block.chainid), addressToHex(GOVERNANCE_SAFE));
        vm.writeFile(path, string.concat(header, _getGnosisTransaction(addressToHex(UPGRADE_TIMELOCK), iToHex(data), "0", true)));
        console.log("Wrote", path);
    }
}
