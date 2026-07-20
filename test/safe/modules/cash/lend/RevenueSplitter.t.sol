// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { AaveV4RevenueSplitter } from "../../../../../src/aave-v4/AaveV4RevenueSplitter.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

interface IOwnable2Step {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

/**
 * @title AaveV4RevenueSplitterTest
 * @notice The splitter owns the TreasurySpoke and splits claimed fees between two immutable recipients.
 *         Claim + split are permissionless; only the ownership escape hatch is owner-gated.
 */
contract AaveV4RevenueSplitterTest is CashGatewayTestSetup {
    AaveV4RevenueSplitter internal splitter;
    address internal etherFiTreasury = makeAddr("etherFiTreasury");
    address internal aaveDao = makeAddr("aaveDao");
    uint256 internal constant SPLIT_BPS_A = 8000; // ether.fi 80%, Aave DAO 20%
    uint256 internal constant SEEDED_FEES = 1_000e6;

    function setUp() public override {
        super.setUp();
        splitter = new AaveV4RevenueSplitter(address(treasurySpoke), etherFiTreasury, aaveDao, SPLIT_BPS_A, owner);

        // Seed deterministic claimable fees while aaveAdmin still owns the treasury, then hand ownership over
        deal(address(usdc), aaveAdmin, SEEDED_FEES);
        vm.startPrank(aaveAdmin);
        usdc.approve(address(treasurySpoke), SEEDED_FEES);
        treasurySpoke.supply(address(hub), address(usdc), SEEDED_FEES);
        IOwnable2Step(address(treasurySpoke)).transferOwnership(address(splitter));
        vm.stopPrank();
        splitter.acceptTreasurySpokeOwnership(); // permissionless
    }

    function test_ownershipHandshake() public view {
        assertEq(IOwnable2Step(address(treasurySpoke)).owner(), address(splitter), "splitter owns the treasury spoke");
    }

    function test_claimAndSplit_splits8020() public {
        splitter.claimAndSplit(address(hub), address(usdc), type(uint256).max); // permissionless full claim
        assertEq(usdc.balanceOf(etherFiTreasury), SEEDED_FEES * SPLIT_BPS_A / 10_000, "ether.fi got 80%");
        assertEq(usdc.balanceOf(aaveDao), SEEDED_FEES - SEEDED_FEES * SPLIT_BPS_A / 10_000, "Aave DAO got 20%");
        assertEq(usdc.balanceOf(address(splitter)), 0, "nothing strands on the splitter");
    }

    function test_split_handlesDirectBalances() public {
        deal(address(usdc), address(splitter), 100e6);
        splitter.split(address(usdc));
        assertEq(usdc.balanceOf(etherFiTreasury), 80e6, "80%");
        assertEq(usdc.balanceOf(aaveDao), 20e6, "20%");
    }

    function test_split_zeroBalance_noop() public {
        splitter.split(address(usdc)); // must not revert
        assertEq(usdc.balanceOf(etherFiTreasury), 0);
    }

    function test_escapeHatch_onlyOwner_and_twoStep() public {
        address newOwner = makeAddr("newTreasuryOwner");
        address rando = makeAddr("rando");

        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        splitter.transferTreasurySpokeOwnership(newOwner);

        vm.prank(owner);
        splitter.transferTreasurySpokeOwnership(newOwner);
        assertEq(IOwnable2Step(address(treasurySpoke)).owner(), address(splitter), "still owner until accepted");
        vm.prank(newOwner);
        IOwnable2Step(address(treasurySpoke)).acceptOwnership();
        assertEq(IOwnable2Step(address(treasurySpoke)).owner(), newOwner, "two-step completed");
    }

    function test_realFeeAccrual_flowsThroughSplitter() public {
        uint256 baseline = treasurySpoke.getSuppliedAssets(address(hub), address(usdc));
        _buildGatewayPosition(address(safe), address(weETH), 10 ether, address(usdc), 10_000e6);
        vm.warp(block.timestamp + 30 days);
        _seedAaveLiquidity(usdcReserveId, address(usdc), 1e6); // poke the hub so interest (and its fee cut) accrues
        assertGt(treasurySpoke.getSuppliedAssets(address(hub), address(usdc)), baseline, "borrow interest accrued fees to the treasury");

        splitter.claimAndSplit(address(hub), address(usdc), type(uint256).max);
        assertGt(usdc.balanceOf(etherFiTreasury), 0, "ether.fi share paid");
        assertGt(usdc.balanceOf(aaveDao), 0, "Aave DAO share paid");
    }
}
