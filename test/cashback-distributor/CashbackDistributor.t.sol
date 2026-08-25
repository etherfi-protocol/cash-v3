// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { CashbackDistributor } from "../../src/cashback-distributor/CashbackDistributor.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { MockTeller } from "../../src/mocks/MockTeller.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";

contract CashbackDistributorTest is Test {
    CashbackDistributor public distributor;
    RoleRegistry public roleRegistry;
    MockERC20 public token;
    MockERC20 public ethfi;
    MockERC20 public sEthfi;
    MockTeller public teller;

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
    event CashbackAwarded(bytes32 indexed claimId, address indexed recipient, address indexed token, uint256 amount, uint256 sEthfiAmount);
    event CashbackBatchAwarded(uint256 count, address token, uint256 total);
    event RescueERC20(address indexed token, address indexed to, uint256 amount);
    event RescueETH(address indexed to, uint256 amount);
    event TellerSet(address indexed teller);

    function setUp() public {
        // ETHFI/sETHFI are immutable, set at implementation deploy, so the mocks must exist first.
        ethfi = new MockERC20("ETHFI", "ETHFI", 18);
        sEthfi = new MockERC20("Staked ETHFI", "sETHFI", 18);
        teller = new MockTeller(sEthfi);

        vm.startPrank(owner);

        address rrImpl = address(new RoleRegistry(dataProviderMock));
        roleRegistry = RoleRegistry(address(new UUPSProxy(rrImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        address distributorImpl = address(new CashbackDistributor(address(ethfi), address(sEthfi)));
        distributor = CashbackDistributor(address(new UUPSProxy(distributorImpl, abi.encodeWithSelector(CashbackDistributor.initialize.selector, address(roleRegistry)))));

        roleRegistry.grantRole(distributor.CASHBACK_DISTRIBUTOR_ROLE(), payoutWallet);
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);
        vm.stopPrank();

        token = new MockERC20("Mock USD", "mUSD", 6);
        token.mint(payoutWallet, 1_000_000e6);

        // The payout wallet still holds balance/allowance from the old EOA-custody model, so
        // tests can prove those no longer matter: `award`/`awardBatch` now pay from the
        // contract's own balance, not via `transferFrom` on the caller.
        vm.prank(payoutWallet);
        token.approve(address(distributor), type(uint256).max);
    }

    /// @dev Sets the teller used by `awardStaked`, for tests that need it.
    function _setTeller() internal {
        vm.prank(owner);
        distributor.setTeller(address(teller));
    }

    /// @dev Funds the contract's own balance of `t` -- the new custody model requires the
    ///      contract itself to hold funds, topped up directly by treasury.
    function _fundContract(MockERC20 t, uint256 amount) internal {
        t.mint(address(distributor), amount);
    }

    // --- constructor ---

    function test_constructor_setsImmutableEthfiAndSEthfi() public view {
        assertEq(distributor.ethfi(), address(ethfi));
        assertEq(distributor.sEthfi(), address(sEthfi));
    }

    function test_constructor_revertsForZeroEthfi() public {
        vm.expectRevert(CashbackDistributor.InvalidValue.selector);
        new CashbackDistributor(address(0), address(sEthfi));
    }

    function test_constructor_revertsForZeroSEthfi() public {
        vm.expectRevert(CashbackDistributor.InvalidValue.selector);
        new CashbackDistributor(address(ethfi), address(0));
    }

    // --- role constant ---

    function test_roleConstant_matchesKeccak() public view {
        assertEq(distributor.CASHBACK_DISTRIBUTOR_ROLE(), keccak256("CASHBACK_DISTRIBUTOR_ROLE"));
    }

    // --- award: happy path ---

    function test_award_byRole_movesTokensAndSettlesAndEmits() public {
        uint256 amount = 100e6;
        _fundContract(token, amount);

        uint256 contractBalanceBefore = token.balanceOf(address(distributor));
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        assertFalse(distributor.settled(CLAIM_1));

        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_1, recipient, address(token), amount, 0);

        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), amount);

        assertTrue(distributor.settled(CLAIM_1));
        assertEq(token.balanceOf(recipient), recipientBalanceBefore + amount);
        assertEq(token.balanceOf(address(distributor)), contractBalanceBefore - amount);
    }

    function test_award_zeroAmount_allowedAndSettles() public {
        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_1, recipient, address(token), 0, 0);

        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), 0);

        assertTrue(distributor.settled(CLAIM_1));
        assertEq(token.balanceOf(recipient), 0);
    }

    // --- award: pays from contract balance, not the caller (transferFrom is gone) ---

    function test_award_paysFromContractBalance_notCaller() public {
        uint256 amount = 100e6;
        _fundContract(token, amount);

        uint256 payoutWalletBalanceBefore = token.balanceOf(payoutWallet);

        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), amount);

        // The caller's (old payout wallet's) balance is untouched -- funds moved from the
        // contract's own balance, never via transferFrom on msg.sender.
        assertEq(token.balanceOf(payoutWallet), payoutWalletBalanceBefore);
        assertEq(token.balanceOf(recipient), amount);
    }

    function test_award_reducesContractBalanceByExactlyAmount() public {
        uint256 funded = 500e6;
        uint256 amount = 100e6;
        _fundContract(token, funded);

        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), amount);

        // Unlike the old EOA-custody model (where the contract never held funds), the contract
        // now custodies payout funds directly, so a residual balance is expected after award.
        assertEq(token.balanceOf(address(distributor)), funded - amount);
    }

    // --- award: double settlement ---

    function test_award_secondCallForSameClaim_reverts() public {
        // Fund enough to cover both the first award and the second (already-settled) attempt,
        // so the balance pre-check doesn't mask the AlreadySettled revert being tested here.
        _fundContract(token, 100e6 + 1);

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
        _fundContract(token, 100e6);

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
        _fundContract(token, 60e6);

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
        emit CashbackAwarded(CLAIM_1, recipient, address(token), 10e6, 0);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_2, recipient2, address(token), 20e6, 0);
        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_3, recipient3, address(token), 30e6, 0);
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
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    // --- awardBatch: one already-settled id ---

    function test_awardBatch_revertsWhenOneClaimAlreadySettled() public {
        // Fund enough to cover the standalone award below plus the batch's total, so the
        // batch's balance pre-check doesn't mask the AlreadySettled revert being tested here.
        _fundContract(token, 35e6);

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
        _fundContract(token, 10e6);

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

    // --- rescueERC20 ---

    function test_rescueERC20_byOwner_movesTokensAndEmits() public {
        uint256 amount = 42e6;
        token.mint(address(distributor), amount);

        uint256 toBalanceBefore = token.balanceOf(recipient);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit RescueERC20(address(token), recipient, amount);

        vm.prank(owner);
        distributor.rescueERC20(address(token), recipient, amount);

        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.balanceOf(recipient), toBalanceBefore + amount);
    }

    function test_rescueERC20_revertsForNonOwner() public {
        token.mint(address(distributor), 42e6);

        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        vm.prank(stranger);
        distributor.rescueERC20(address(token), recipient, 42e6);
    }

    function test_rescueERC20_revertsForZeroAddressTo() public {
        token.mint(address(distributor), 42e6);

        vm.expectRevert(CashbackDistributor.InvalidRecipient.selector);
        vm.prank(owner);
        distributor.rescueERC20(address(token), address(0), 42e6);
    }

    // --- rescueERC20: type(uint256).max sentinel resolves to the full balance at execution time ---

    function test_rescueERC20_maxSentinel_rescuesFullBalance() public {
        uint256 amount = 17e6;
        token.mint(address(distributor), amount);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit RescueERC20(address(token), recipient, amount);

        vm.prank(owner);
        distributor.rescueERC20(address(token), recipient, type(uint256).max);

        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.balanceOf(recipient), amount);
    }

    function test_rescueERC20_maxSentinel_resolvesAtExecutionTime_notQueueTime() public {
        // Simulate a timelocked call being "queued" against one balance, then the contract's
        // balance changing before it actually executes -- the sentinel must resolve against
        // the balance at execution time, not whatever it was when the call was constructed.
        token.mint(address(distributor), 10e6);

        // Balance changes after "queueing" (more funds arrive before execution).
        token.mint(address(distributor), 5e6);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit RescueERC20(address(token), recipient, 15e6);

        vm.prank(owner);
        distributor.rescueERC20(address(token), recipient, type(uint256).max);

        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.balanceOf(recipient), 15e6);
    }

    function test_rescueERC20_explicitAmount_stillWorks() public {
        token.mint(address(distributor), 50e6);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit RescueERC20(address(token), recipient, 20e6);

        vm.prank(owner);
        distributor.rescueERC20(address(token), recipient, 20e6);

        assertEq(token.balanceOf(address(distributor)), 30e6);
        assertEq(token.balanceOf(recipient), 20e6);
    }

    // --- rescueERC20: still works for contract-held ETHFI under the new custody model ---

    function test_rescueERC20_worksForContractHeldEthfi() public {
        uint256 amount = 7 ether;
        ethfi.mint(address(distributor), amount);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit RescueERC20(address(ethfi), recipient, amount);

        vm.prank(owner);
        distributor.rescueERC20(address(ethfi), recipient, amount);

        assertEq(ethfi.balanceOf(address(distributor)), 0);
        assertEq(ethfi.balanceOf(recipient), amount);
    }

    // --- rescueETH ---

    function test_rescueETH_byOwner_movesEthAndEmits() public {
        uint256 amount = 3 ether;
        vm.deal(address(distributor), amount);

        uint256 toBalanceBefore = recipient.balance;

        vm.expectEmit(true, true, true, true, address(distributor));
        emit RescueETH(recipient, amount);

        vm.prank(owner);
        distributor.rescueETH(recipient, amount);

        assertEq(address(distributor).balance, 0);
        assertEq(recipient.balance, toBalanceBefore + amount);
    }

    // --- rescueETH: type(uint256).max sentinel resolves to the full balance at execution time ---

    function test_rescueETH_maxSentinel_rescuesFullBalance() public {
        uint256 amount = 4 ether;
        vm.deal(address(distributor), amount);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit RescueETH(recipient, amount);

        vm.prank(owner);
        distributor.rescueETH(recipient, type(uint256).max);

        assertEq(address(distributor).balance, 0);
        assertEq(recipient.balance, amount);
    }

    function test_rescueETH_maxSentinel_resolvesAtExecutionTime_notQueueTime() public {
        // Same timelock scenario as the ERC20 case: the balance at "queue" time differs from
        // the balance when the rescue actually executes, and the sentinel must track the latter.
        vm.deal(address(distributor), 2 ether);

        // Balance changes after "queueing".
        vm.deal(address(distributor), address(distributor).balance + 1 ether);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit RescueETH(recipient, 3 ether);

        vm.prank(owner);
        distributor.rescueETH(recipient, type(uint256).max);

        assertEq(address(distributor).balance, 0);
        assertEq(recipient.balance, 3 ether);
    }

    function test_rescueETH_explicitAmount_stillWorks() public {
        vm.deal(address(distributor), 10 ether);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit RescueETH(recipient, 4 ether);

        vm.prank(owner);
        distributor.rescueETH(recipient, 4 ether);

        assertEq(address(distributor).balance, 6 ether);
        assertEq(recipient.balance, 4 ether);
    }

    function test_rescueETH_revertsForNonOwner() public {
        vm.deal(address(distributor), 3 ether);

        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        vm.prank(stranger);
        distributor.rescueETH(recipient, 3 ether);
    }

    function test_rescueETH_revertsForZeroAddressTo() public {
        vm.deal(address(distributor), 3 ether);

        vm.expectRevert(CashbackDistributor.InvalidRecipient.selector);
        vm.prank(owner);
        distributor.rescueETH(address(0), 3 ether);
    }

    // --- award: insufficient balance pre-check (now against the contract's own balance) ---

    function test_award_revertsWithInsufficientBalance_whenContractUnfunded() public {
        uint256 amount = 100e6;

        // The old payout wallet still has plenty of balance and a full allowance -- proving
        // transferFrom is gone: only the contract's own (zero) balance matters now.
        assertEq(token.balanceOf(payoutWallet), 1_000_000e6);
        assertGe(token.allowance(payoutWallet, address(distributor)), amount);

        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.InsufficientBalance.selector, address(token), amount, 0));
        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), amount);
    }

    function test_award_insufficientBalance_doesNotSettleClaim_thenSucceedsAfterFunding() public {
        uint256 amount = 100e6;

        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.InsufficientBalance.selector, address(token), amount, 0));
        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), amount);

        assertFalse(distributor.settled(CLAIM_1));

        // Fund the contract itself (the new custody model), not the old payout wallet.
        _fundContract(token, amount);

        vm.prank(payoutWallet);
        distributor.award(CLAIM_1, recipient, address(token), amount);

        assertTrue(distributor.settled(CLAIM_1));
        assertEq(token.balanceOf(recipient), amount);
    }

    // --- awardBatch: insufficient balance pre-check (total vs. the contract's own balance) ---

    function test_awardBatch_revertsWithInsufficientBalance_totalAcrossBatch() public {
        uint256 amount0 = 10e6;
        uint256 amount1 = 1;
        uint256 total = amount0 + amount1;

        // Fund the contract with less than the batch total.
        _fundContract(token, amount0);

        bytes32[] memory claimIds = new bytes32[](2);
        claimIds[0] = CLAIM_1;
        claimIds[1] = CLAIM_2;

        address[] memory recipients = new address[](2);
        recipients[0] = recipient;
        recipients[1] = recipient2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.InsufficientBalance.selector, address(token), total, amount0));
        vm.prank(payoutWallet);
        distributor.awardBatch(claimIds, recipients, address(token), amounts);

        assertFalse(distributor.settled(CLAIM_1));
        assertFalse(distributor.settled(CLAIM_2));
        assertEq(token.balanceOf(recipient), 0);
    }

    // --- setTeller ---

    function test_setTeller_byOwner_setsTellerAndEmits() public {
        vm.expectEmit(true, true, true, true, address(distributor));
        emit TellerSet(address(teller));

        vm.prank(owner);
        distributor.setTeller(address(teller));

        assertEq(distributor.teller(), address(teller));
    }

    function test_setTeller_revertsForNonOwner() public {
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        vm.prank(stranger);
        distributor.setTeller(address(teller));
    }

    function test_setTeller_revertsForZeroAddress() public {
        vm.expectRevert(CashbackDistributor.InvalidValue.selector);
        vm.prank(owner);
        distributor.setTeller(address(0));
    }

    function test_setTeller_revertsWhenVaultMismatch() public {
        // A teller whose vault() is a different token than the sEthfi immutable.
        MockERC20 wrongShareToken = new MockERC20("Wrong Share", "wSHARE", 18);
        MockTeller wrongTeller = new MockTeller(wrongShareToken);

        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.TellerVaultMismatch.selector, address(sEthfi), address(wrongShareToken)));
        vm.prank(owner);
        distributor.setTeller(address(wrongTeller));
    }

    function test_setTeller_revertsWhenShareLockPeriodNonzero() public {
        uint64 lockPeriod = 1 days;
        teller.setShareLockPeriod(lockPeriod);

        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.TellerSharesLocked.selector, lockPeriod));
        vm.prank(owner);
        distributor.setTeller(address(teller));

        // The rejected teller was never stored.
        assertEq(distributor.teller(), address(0));
    }

    function test_setTeller_succeedsWhenTellerDoesNotImplementShareLockPeriod() public {
        // A contract with no shareLockPeriod()/vault() at all would fail the mandatory vault()
        // check first, so this only demonstrates the shareLockPeriod best-effort behavior in
        // isolation: a teller that implements vault() correctly but not shareLockPeriod().
        MockTellerWithoutShareLock bareTeller = new MockTellerWithoutShareLock(address(sEthfi));

        vm.prank(owner);
        distributor.setTeller(address(bareTeller));

        assertEq(distributor.teller(), address(bareTeller));
    }

    // --- awardStaked: unconfigured ---

    function test_awardStaked_revertsWhenTellerNotSet() public {
        _fundContract(ethfi, 100 ether);

        vm.expectRevert(CashbackDistributor.TellerNotSet.selector);
        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, 100 ether, 100 ether);
    }

    // --- awardStaked: happy path ---

    function test_awardStaked_happyPath_depositsSharesAndSettlesAndEmits() public {
        _setTeller();

        uint256 ethfiAmount = 100 ether;
        uint256 minShares = 100 ether;
        _fundContract(ethfi, ethfiAmount);

        assertFalse(distributor.settled(CLAIM_1));

        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_1, recipient, address(sEthfi), ethfiAmount, minShares);

        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, ethfiAmount, minShares);

        assertTrue(distributor.settled(CLAIM_1));
        assertEq(ethfi.balanceOf(address(distributor)), 0);
        assertEq(ethfi.balanceOf(address(teller)), ethfiAmount);
        assertEq(sEthfi.balanceOf(recipient), minShares);
        assertEq(sEthfi.balanceOf(address(distributor)), 0);
    }

    function test_awardStaked_appliesTellerPremium_sharesMintedReflectDiscount() public {
        _setTeller();

        uint256 ethfiAmount = 100 ether;
        // 5% premium/fee taken by the teller.
        teller.setPremiumBps(500);
        uint256 expectedShares = 95 ether;

        _fundContract(ethfi, ethfiAmount);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit CashbackAwarded(CLAIM_1, recipient, address(sEthfi), ethfiAmount, expectedShares);

        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, ethfiAmount, expectedShares);

        assertEq(sEthfi.balanceOf(recipient), expectedShares);
    }

    function test_awardStaked_resetsApprovalToZero() public {
        _setTeller();

        uint256 ethfiAmount = 100 ether;
        _fundContract(ethfi, ethfiAmount);

        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, ethfiAmount, ethfiAmount);

        assertEq(ethfi.allowance(address(distributor), address(teller)), 0);
    }

    // --- awardStaked: insufficient ETHFI balance pre-check ---

    function test_awardStaked_revertsWhenInsufficientEthfiBalance() public {
        _setTeller();

        uint256 ethfiAmount = 100 ether;
        _fundContract(ethfi, ethfiAmount - 1);

        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.InsufficientBalance.selector, address(ethfi), ethfiAmount, ethfiAmount - 1));
        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, ethfiAmount, ethfiAmount);

        assertFalse(distributor.settled(CLAIM_1));
    }

    // --- awardStaked: minShares violation (teller does not enforce it itself) ---

    function test_awardStaked_revertsWhenBelowMinShares_andDoesNotSettle() public {
        _setTeller();

        uint256 ethfiAmount = 100 ether;
        uint256 minShares = 96 ether;

        // 5% premium yields 95e18 shares -- below minShares. Disable the mock's own
        // minimumMint enforcement so the contract's own post-deposit check is what fires.
        teller.setPremiumBps(500);
        teller.setEnforceMinimumMint(false);

        _fundContract(ethfi, ethfiAmount);

        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.InsufficientSharesMinted.selector, minShares, 95 ether));
        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, ethfiAmount, minShares);

        assertFalse(distributor.settled(CLAIM_1));
        assertEq(sEthfi.balanceOf(recipient), 0);
    }

    function test_awardStaked_revertsWhenTellerEnforcesMinimumMint() public {
        _setTeller();

        uint256 ethfiAmount = 100 ether;
        uint256 minShares = 96 ether;

        // 5% premium yields 95e18 shares -- below minShares. The mock teller enforces its own
        // minimumMint by default (mirroring a real teller), so it reverts before the
        // distributor's own check would run.
        teller.setPremiumBps(500);

        _fundContract(ethfi, ethfiAmount);

        vm.expectRevert("MockTeller: minimumMint not met");
        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, ethfiAmount, minShares);

        assertFalse(distributor.settled(CLAIM_1));
    }

    // --- awardStaked: double settlement ---

    function test_awardStaked_secondCallForSameClaim_reverts() public {
        _setTeller();

        uint256 ethfiAmount = 100 ether;
        _fundContract(ethfi, ethfiAmount * 2);

        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, ethfiAmount, ethfiAmount);

        vm.expectRevert(abi.encodeWithSelector(CashbackDistributor.AlreadySettled.selector, CLAIM_1));
        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, ethfiAmount, ethfiAmount);
    }

    // --- awardStaked: role gate ---

    function test_awardStaked_revertsForNonRoleCaller() public {
        _setTeller();
        _fundContract(ethfi, 100 ether);

        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        vm.prank(stranger);
        distributor.awardStaked(CLAIM_1, recipient, 100 ether, 100 ether);
    }

    // --- awardStaked: pause gate ---

    function test_awardStaked_revertsWhenPaused() public {
        _setTeller();
        _fundContract(ethfi, 100 ether);

        vm.prank(pauser);
        distributor.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, 100 ether, 100 ether);
    }

    function test_awardStaked_succeedsAfterUnpause() public {
        _setTeller();
        _fundContract(ethfi, 100 ether);

        vm.prank(pauser);
        distributor.pause();

        vm.prank(unpauser);
        distributor.unpause();

        vm.prank(payoutWallet);
        distributor.awardStaked(CLAIM_1, recipient, 100 ether, 100 ether);

        assertTrue(distributor.settled(CLAIM_1));
        assertEq(sEthfi.balanceOf(recipient), 100 ether);
    }

    // --- initializer ---

    function test_initialize_revertsOnSecondCall() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        distributor.initialize(address(roleRegistry));
    }

    // --- upgrade authorization ---

    function test_upgrade_succeedsForRoleRegistryOwner() public {
        address newImpl = address(new CashbackDistributor(address(ethfi), address(sEthfi)));

        vm.prank(owner);
        distributor.upgradeToAndCall(newImpl, "");
    }

    function test_upgrade_revertsForNonOwner() public {
        address newImpl = address(new CashbackDistributor(address(ethfi), address(sEthfi)));

        vm.prank(stranger);
        vm.expectRevert(RoleRegistry.OnlyUpgrader.selector);
        distributor.upgradeToAndCall(newImpl, "");
    }
}

/**
 * @dev A bare-bones teller stub that implements `vault()` (so it passes CashbackDistributor's
 *      mandatory vault-match check) but not `shareLockPeriod()`, used to exercise the
 *      best-effort nature of that check in `setTeller`: a teller that doesn't implement
 *      `shareLockPeriod()` at all must not block `setTeller` from succeeding.
 */
contract MockTellerWithoutShareLock {
    address private immutable _vault;

    constructor(address vault_) {
        _vault = vault_;
    }

    function vault() external view returns (address) {
        return _vault;
    }
}
