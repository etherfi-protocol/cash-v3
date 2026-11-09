// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test, Vm } from "forge-std/Test.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";

contract TopUpDestCosignerForkTest is Test {
    address internal constant TOP_UP_DEST = 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    uint256 internal constant SIGNER_KEY = 0xC0516;

    TopUpDest internal dest = TopUpDest(payable(TOP_UP_DEST));
    TopUpDest.TopUpApproval internal historical;
    address internal worker;
    uint256 internal balanceBefore;

    function setUp() public {
        string memory rpc = vm.envOr("OPTIMISM_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        uint256 forkBlock = vm.envOr("TOP_UP_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        assertEq(block.chainid, 10, "Optimism fork required");

        // Use an actual completed USDC payout from before the upgrade.
        Vm.EthGetLogs memory prior = _historicalPayout();
        assertEq(prior.emitter, TOP_UP_DEST, "No recent USDC payout");
        address user = address(uint160(uint256(prior.topics[2])));
        (bytes32 txHash, uint256 sourceChainId,) = abi.decode(prior.data, (bytes32, uint256, uint256));
        assertTrue(dest.isTransactionCompleted(txHash, user, USDC));

        uint256 depositBefore = dest.getDeposit(USDC);
        balanceBefore = IERC20(USDC).balanceOf(TOP_UP_DEST);
        bool pausedBefore = dest.paused();
        assertFalse(pausedBefore, "Choose an unpaused fork block for payout verification");
        assertGe(balanceBefore, 1e6, "Live USDC float required");
        RoleRegistry registry = RoleRegistry(address(dest.roleRegistry()));
        worker = registry.roleHolders(uint256(dest.TOP_UP_ROLE()))[0];
        address admin = registry.roleHolders(uint256(registry.ADMIN_TIMELOCK_ROLE()))[0];
        address implementation = address(new TopUpDest(address(dest.etherFiDataProvider()), address(dest.weth())));
        emit log_named_uint("Fork block", block.number);

        vm.prank(registry.owner());
        dest.upgradeToAndCall(implementation, "");
        assertEq(address(dest.roleRegistry()), address(registry));
        assertEq(dest.getDeposit(USDC), depositBefore);
        assertEq(IERC20(USDC).balanceOf(TOP_UP_DEST), balanceBefore);
        assertEq(dest.paused(), pausedBefore);
        assertTrue(dest.isTransactionCompletedByTxId(prior.topics[1]));
        (address signer, bool required, uint256 epoch) = dest.cosignerConfig();
        assertEq(signer, address(0));
        assertFalse(required);
        assertEq(epoch, 0);
        historical = TopUpDest.TopUpApproval(txHash, user, sourceChainId + 1, USDC, 1e6, block.timestamp + 300);
        vm.prank(admin);
        dest.configureCosigner(vm.addr(SIGNER_KEY), true);
    }

    /// @notice Checks a real completion record and signed payouts against the upgraded deployed proxy.
    function test_upgradePreservesHistoricalCompletionAndEnforcesApprovals() public {
        TopUpDest.TopUpApproval memory approval = historical;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, dest.getTopUpApprovalDigest(approval));
        vm.expectRevert(TopUpDest.TopUpAlreadyProcessed.selector);
        vm.prank(worker);
        dest.topUpUserSafeWithApproval(approval, abi.encodePacked(r, s, v));

        approval.txHash = keccak256("fork-only new payout");
        assertFalse(dest.isTransactionCompleted(approval.txHash, approval.user, USDC));
        vm.expectRevert(TopUpDest.CosignerRequired.selector);
        vm.prank(worker);
        dest.topUpUserSafe(approval.txHash, approval.user, approval.sourceChainId, USDC, approval.amount);

        (v, r, s) = vm.sign(SIGNER_KEY, dest.getTopUpApprovalDigest(approval));
        approval.amount++;
        vm.expectRevert(TopUpDest.InvalidCosignature.selector);
        vm.prank(worker);
        dest.topUpUserSafeWithApproval(approval, abi.encodePacked(r, s, v));
        assertEq(IERC20(USDC).balanceOf(TOP_UP_DEST), balanceBefore);
        assertFalse(dest.isTransactionCompleted(approval.txHash, approval.user, USDC));

        approval.amount--;
        vm.prank(worker);
        dest.topUpUserSafeWithApproval(approval, abi.encodePacked(r, s, v));
        assertTrue(dest.isTransactionCompleted(approval.txHash, approval.user, USDC));
        assertEq(IERC20(USDC).balanceOf(TOP_UP_DEST), balanceBefore - approval.amount);
    }

    /// @notice Finds a recent USDC payout using ranges supported by the RPC's free tier.
    /// @return Historical payout event whose completion must survive the upgrade
    function _historicalPayout() internal returns (Vm.EthGetLogs memory) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("TopUp(bytes32,address,address,bytes32,uint256,uint256)");
        for (uint256 end = block.number; end > block.number - 1000; end -= 10) {
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(end - 9, end, TOP_UP_DEST, topics);
            for (uint256 i = logs.length; i > 0; --i) {
                if (address(uint160(uint256(logs[i - 1].topics[3]))) == USDC) {
                    return logs[i - 1];
                }
            }
        }
        revert("No USDC payout in the last 1,000 blocks; select an active fork block");
    }
}
