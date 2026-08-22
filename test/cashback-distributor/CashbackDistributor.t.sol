// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { CashbackDistributor } from "../../src/cashback-distributor/CashbackDistributor.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";

contract CashbackDistributorTest is Test {
    CashbackDistributor public distributor;
    RoleRegistry public roleRegistry;
    MockERC20 public token;

    address public owner = makeAddr("owner");
    address public payoutWallet = makeAddr("payoutWallet");
    address public recipient = makeAddr("recipient");
    address public recipient2 = makeAddr("recipient2");
    address public recipient3 = makeAddr("recipient3");
    address public stranger = makeAddr("stranger");
    address public dataProviderMock = makeAddr("dataProvider");
    address public pauser = makeAddr("pauser");
    address public unpauser = makeAddr("unpauser");

    bytes32 internal constant CLAIM_1 = keccak256("claim-1");
    bytes32 internal constant CLAIM_2 = keccak256("claim-2");
    bytes32 internal constant CLAIM_3 = keccak256("claim-3");

    // Mirror of the contract event for vm.expectEmit.
    event CashbackAwarded(bytes32 indexed claimId, address indexed recipient, address indexed token, uint256 amount);
    event CashbackBatchAwarded(uint256 count, address token, uint256 total);

    function setUp() public {
        vm.startPrank(owner);

        address rrImpl = address(new RoleRegistry(dataProviderMock));
        roleRegistry = RoleRegistry(address(new UUPSProxy(rrImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        address distributorImpl = address(new CashbackDistributor());
        distributor = CashbackDistributor(address(new UUPSProxy(distributorImpl, abi.encodeWithSelector(CashbackDistributor.initialize.selector, address(roleRegistry)))));

        roleRegistry.grantRole(distributor.CASHBACK_DISTRIBUTOR_ROLE(), payoutWallet);
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);
        vm.stopPrank();

        token = new MockERC20("Mock USD", "mUSD", 6);
        token.mint(payoutWallet, 1_000_000e6);

        vm.prank(payoutWallet);
        token.approve(address(distributor), type(uint256).max);
    }

    // --- role constant ---

    function test_roleConstant_matchesKeccak() public view {
        assertEq(distributor.CASHBACK_DISTRIBUTOR_ROLE(), keccak256("CASHBACK_DISTRIBUTOR_ROLE"));
    }

    // --- award: happy path ---

    function test_award_byRole_movesTokensAndSettlesAndEmits() public {
        uint256 amount = 100e6;
        uint256 payoutBalanceBefore = token.balanceOf(payoutWallet);
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        assertFalse(distributor.settled(CLAIM_1));

        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_1, recipient, address(token), amount);

        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), amount);

        assertTrue(distributor.settled(CLAIM_1));
        assertEq(token.balanceOf(recipient), recipientBalanceBefore + amount);
        assertEq(token.balanceOf(payoutWallet), payoutBalanceBefore - amount);
    }

    function test_award_zeroAmount_allowedAndSettles() public {
        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_1, recipient, address(token), 0);

        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), 0);

        assertTrue(distributor.settled(CLAIM_1));
        assertEq(token.balanceOf(recipient), 0);
    }

    // --- award: double settlement ---

    function test_award_secondCallForSameClaim_reverts() public {
        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), 100e6);

        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.AlreadySettled.selector, CLAIM_1));
        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), 1);
    }

    // --- award: role gate ---

    function test_award_revertsForNonRoleCaller() public {
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        vm.prank(stranger);
        distributor.award(CLAIM_1, recipient, address(token), 100e6);
    }

    // --- award: pause gate ---

    function test_award_revertsWhenPaused() public {
        vm.prank(pauser);
        distributor.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), 100e6);
    }

    function test_award_succeedsAfterUnpause() public {
        vm.prank(pauser);
        distributor.pause();

        vm.prank(unpauser);
        distributor.unpause();

        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), 100e6);

        assertTrue(distributor.settled(CLAIM_1));
        assertEq(token.balanceOf(recipient), 100e6);
    }

    // --- awardBatch: happy path ---

    function test_awardBatch_byRole_movesTokensAndSettlesAllAndEmits() public {
        bytes32[] memory claimIds = new bytes32[](3);
        claimIds[0] = CLAIM_1;
        claimIds[1] = CLAIM_2;
        claimIds[2] = CLAIM_3;

        address[] memory recipients = new address[](3);
        recipients[0] = recipient;
        recipients[1] = recipient2;
        recipients[2] = recipient3;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 10e6;
        amounts[1] = 20e6;
        amounts[2] = 30e6;

        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_1, recipient, address(token), 10e6);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_2, recipient2, address(token), 20e6);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_3, recipient3, address(token), 30e6);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackBatchAwarded(3, address(token), 60e6);

        vm.prank(payoutWallet);
        distributor.awardBatch(claimIds, recipients, address(token), amounts);

        assertTrue(distributor.settled(CLAIM_1));
        assertTrue(distributor.settled(CLAIM_2));
        assertTrue(distributor.settled(CLAIM_3));
        assertEq(token.balanceOf(recipient), 10e6);
        assertEq(token.balanceOf(recipient2), 20e6);
        assertEq(token.balanceOf(recipient3), 30e6);
    }

    // --- awardBatch: one already-settled id ---

    function test_awardBatch_revertsWhenOneClaimAlreadySettled() public {
        vm.prank(payoutWallet);
        distributor.award(CLAIM_2, recipient2, address(token), 5e6);

        bytes32[] memory claimIds = new bytes32[](2);
        claimIds[0] = CLAIM_1;
        claimIds[1] = CLAIM_2;

        address[] memory recipients = new address[](2);
        recipients[0] = recipient;
        recipients[1] = recipient2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e6;
        amounts[1] = 20e6;

        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.AlreadySettled.selector, CLAIM_2));
        vm.prank(payoutWallet);
        distributor.awardBatch(claimIds, recipients, address(token), amounts);

        // Nothing from the batch should have settled or moved (whole tx reverts).
        assertFalse(distributor.settled(CLAIM_1));
        assertEq(token.balanceOf(recipient), 0);
    }

    // --- awardBatch: length mismatch ---

    function test_awardBatch_revertsOnRecipientsLengthMismatch() public {
        bytes32[] memory claimIds = new bytes32[](2);
        claimIds[0] = CLAIM_1;
        claimIds[1] = CLAIM_2;

        address[] memory recipients = new address[](1);
        recipients[0] = recipient;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e6;
        amounts[1] = 20e6;

        vm.expectRevert(CashbackDistributor.ArrayLengthMismatch.selector);
        vm.prank(payoutWallet);
        distributor.awardBatch(claimIds, recipients, address(token), amounts);
    }

    function test_awardBatch_revertsOnAmountsLengthMismatch() public {
        bytes32[] memory claimIds = new bytes32[](2);
        claimIds[0] = CLAIM_1;
        claimIds[1] = CLAIM_2;

        address[] memory recipients = new address[](2);
        recipients[0] = recipient;
        recipients[1] = recipient2;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;

        vm.expectRevert(CashbackDistributor.ArrayLengthMismatch.selector);
        vm.prank(payoutWallet);
        distributor.awardBatch(claimIds, recipients, address(token), amounts);
    }

    function test_awardBatch_revertsForNonRoleCaller() public {
        bytes32[] memory claimIds = new bytes32[](1);
        claimIds[0] = CLAIM_1;

        address[] memory recipients = new address[](1);
        recipients[0] = recipient;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;

        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        vm.prank(stranger);
        distributor.awardBatch(claimIds, recipients, address(token), amounts);
    }

    // --- awardBatch: pause gate ---

    function test_awardBatch_revertsWhenPaused() public {
        vm.prank(pauser);
        distributor.pause();

        bytes32[] memory claimIds = new bytes32[](1);
        claimIds[0] = CLAIM_1;

        address[] memory recipients = new address[](1);
        recipients[0] = recipient;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(payoutWallet);
        distributor.awardBatch(claimIds, recipients, address(token), amounts);
    }

    function test_awardBatch_succeedsAfterUnpause() public {
        vm.prank(pauser);
        distributor.pause();

        vm.prank(unpauser);
        distributor.unpause();

        bytes32[] memory claimIds = new bytes32[](1);
        claimIds[0] = CLAIM_1;

        address[] memory recipients = new address[](1);
        recipients[0] = recipient;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e6;

        vm.prank(payoutWallet);
        distributor.awardBatch(claimIds, recipients, address(token), amounts);

        assertTrue(distributor.settled(CLAIM_1));
        assertEq(token.balanceOf(recipient), 10e6);
    }

    // --- no funds held, no rescue path ---

    function test_contractHoldsNoBalanceAfterAward() public {
        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), 100e6);

        assertEq(token.balanceOf(address(distributor)), 0);
    }

    // --- initializer ---

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        distributor.initialize(address(roleRegistry));
    }

    // --- upgrade authorization ---

    function test_upgrade_succeedsForRoleRegistryOwner() public {
        address newImpl = address(new CashbackDistributor());

        vm.prank(owner);
        distributor.upgradeToAndCall(newImpl, "");
    }

    function test_upgrade_revertsForNonOwner() public {
        address newImpl = address(new CashbackDistributor());

        vm.prank(stranger);
        vm.expectRevert(RoleRegistry.OnlyUpgrader.selector);
        distributor.upgradeToAndCall(newImpl, "");
    }
}
