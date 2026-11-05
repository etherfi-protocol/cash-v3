// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IEtherFiDataProvider } from "../../src/interfaces/IEtherFiDataProvider.sol";
import { ILendGateway } from "../../src/interfaces/ILendGateway.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { PausableUpgradeable, UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { TopUpDestBeforeCosigner } from "./fixtures/TopUpDestBeforeCosigner.sol";
import { ERC4626Mock } from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import { Test } from "forge-std/Test.sol";

contract TopUpDestCosignerTest is Test {
    TopUpDest internal dest;
    RoleRegistry internal registry;
    MockERC20 internal token;
    address internal provider = makeAddr("provider");
    address internal worker = makeAddr("worker");
    address internal user = makeAddr("user");
    uint256 internal constant SIGNER_KEY = 0xC0516;
    bytes32 internal constant OLD_TX = keccak256("completed before upgrade");

    function setUp() public {
        vm.warp(1000);
        vm.mockCall(provider, abi.encodeWithSelector(IEtherFiDataProvider.isEtherFiSafe.selector, user), abi.encode(true));
        registry = RoleRegistry(address(new UUPSProxy(address(new RoleRegistry(provider)), abi.encodeCall(RoleRegistry.initialize, (address(this))))));
        registry.grantRole(keccak256("TOP_UP_ROLE"), worker);
        registry.grantRole(keccak256("DEPOSITOR_ROLE"), address(this));
        registry.grantRole(registry.ADMIN_TIMELOCK_ROLE(), address(this));
        registry.grantRole(registry.PAUSER(), address(this));
        registry.grantRole(registry.UNPAUSER(), address(this));
        token = new MockERC20("Token", "TKN", 18);
        TopUpDestBeforeCosigner old = TopUpDestBeforeCosigner(payable(address(new UUPSProxy(address(new TopUpDestBeforeCosigner(provider, address(1))), abi.encodeCall(TopUpDestBeforeCosigner.initialize, (address(registry)))))));
        token.approve(address(old), 100 ether);
        old.deposit(address(token), 100 ether);
        vm.prank(worker);
        old.topUpUserSafe(OLD_TX, user, 1, address(token), 1 ether);
        old.upgradeToAndCall(address(new TopUpDest(provider, address(1))), "");
        dest = TopUpDest(payable(address(old)));
    }

    function approval() internal view returns (TopUpDest.TopUpApproval memory) {
        return TopUpDest.TopUpApproval(keccak256("new deposit"), user, 1, address(token), 2 ether, block.timestamp + 300);
    }

    function sign(TopUpDest target, TopUpDest.TopUpApproval memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, target.getTopUpApprovalDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function enable() internal {
        dest.configureCosigner(vm.addr(SIGNER_KEY), true);
    }

    function submit(TopUpDest.TopUpApproval memory a, bytes memory sig) internal {
        vm.prank(worker);
        dest.topUpUserSafeWithApproval(a, sig);
    }

    function test_upgradePreservesStateAndStartsDisabled() public view {
        assertEq(dest.getDeposit(address(token)), 100 ether);
        assertTrue(dest.isTransactionCompleted(OLD_TX, user, address(token)));
        assertTrue(dest.isTransactionCompletedByTxId(keccak256(abi.encode(OLD_TX, user, address(token)))));
        assertEq(address(dest.roleRegistry()), address(registry));
        (address signer, bool required, uint256 epoch) = dest.cosignerConfig();
        assertEq(signer, address(0));
        assertFalse(required);
        assertEq(epoch, 0);
    }

    function test_upgradePreservesWrapperAndPauseState() public {
        TopUpDestBeforeCosigner old = TopUpDestBeforeCosigner(payable(address(new UUPSProxy(address(new TopUpDestBeforeCosigner(provider, address(1))), abi.encodeCall(TopUpDestBeforeCosigner.initialize, (address(registry)))))));
        ERC4626Mock wrapper = new ERC4626Mock(address(token));
        address[] memory raws = new address[](1);
        address[] memory wrappers = new address[](1);
        raws[0] = address(token);
        wrappers[0] = address(wrapper);
        old.setStockWrappers(raws, wrappers);
        old.pause();
        old.upgradeToAndCall(address(new TopUpDest(provider, address(1))), "");
        TopUpDest upgraded = TopUpDest(payable(address(old)));
        assertEq(upgraded.stockWrapperFor(address(token)), address(wrapper));
        assertTrue(upgraded.paused());
        upgraded.configureCosigner(vm.addr(SIGNER_KEY), true);
        assertEq(upgraded.stockWrapperFor(address(token)), address(wrapper));
        assertTrue(upgraded.paused());
    }

    function testFuzz_idFormulaUnchanged(bytes32 hash, address safe, address asset) public view {
        assertEq(dest.getTxId(hash, safe, asset), keccak256(abi.encode(hash, safe, asset)));
    }

    function test_preUpgradeCompletionRejectsFreshApprovalWithChangedAmountAndChain() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        a.txHash = OLD_TX;
        a.sourceChainId = 42_161;
        a.amount = 3 ether;
        bytes memory sig = sign(dest, a);
        vm.expectRevert(TopUpDest.TopUpAlreadyProcessed.selector);
        submit(a, sig);
        assertEq(token.balanceOf(user), 1 ether);
    }

    function test_legacyWorksBeforeEnforcement() public {
        vm.prank(worker);
        dest.topUpUserSafe(keccak256("legacy"), user, 1, address(token), 1 ether);
    }

    function test_legacySingleBlockedAfterEnforcement() public {
        enable();
        vm.expectRevert(TopUpDest.CosignerRequired.selector);
        vm.prank(worker);
        dest.topUpUserSafe(keccak256("legacy"), user, 1, address(token), 1 ether);
    }

    function test_legacyBatchBlockedAfterEnforcement() public {
        enable();
        vm.expectRevert(TopUpDest.CosignerRequired.selector);
        vm.prank(worker);
        dest.topUpUserSafeBatch(new bytes32[](0), new address[](0), new uint256[](0), new address[](0), new uint256[](0));
    }

    function test_validApprovalAndDuplicateRejected() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        bytes memory sig = sign(dest, a);
        submit(a, sig);
        assertEq(token.balanceOf(user), 3 ether);
        assertTrue(dest.isTransactionCompleted(a.txHash, a.user, a.token));
        vm.expectRevert(TopUpDest.TopUpAlreadyProcessed.selector);
        submit(a, sig);
    }

    function testFuzz_allPayoutFieldsBound(uint8 field) public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        bytes memory sig = sign(dest, a);
        field = uint8(bound(field, 0, 5));
        if (field == 0) a.txHash = keccak256("altered");
        if (field == 1) a.user = address(123);
        if (field == 2) a.sourceChainId++;
        if (field == 3) a.token = address(456);
        if (field == 4) a.amount++;
        if (field == 5) a.deadline++;
        vm.expectRevert(TopUpDest.InvalidCosignature.selector);
        submit(a, sig);
    }

    function test_digestMatchesPublishedSchema() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        bytes32 domain = keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"), keccak256("EtherFiTopUpDest"), keccak256("1"), block.chainid, address(dest)));
        bytes32 payload = keccak256(abi.encode(keccak256("TopUpApproval(bytes32 txHash,address user,uint256 sourceChainId,address token,uint256 amount,uint256 deadline,uint256 epoch)"), a.txHash, a.user, a.sourceChainId, a.token, a.amount, a.deadline, uint256(1)));
        assertEq(dest.getTopUpApprovalDigest(a), keccak256(abi.encodePacked(hex"1901", domain, payload)));
    }

    function test_highSSignatureRejected() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, dest.getTopUpApprovalDigest(a));
        bytes32 highS = bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141) - uint256(s));
        bytes memory sig = abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(TopUpDest.InvalidCosignature.selector);
        submit(a, sig);
    }

    function test_expiredApprovalRejected() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        bytes memory sig = sign(dest, a);
        vm.warp(a.deadline + 1);
        vm.expectRevert(TopUpDest.ApprovalExpired.selector);
        submit(a, sig);
    }

    function test_deadlineInclusive() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        bytes memory sig = sign(dest, a);
        vm.warp(a.deadline);
        submit(a, sig);
    }

    function test_wrongSignerRejected() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1234, dest.getTopUpApprovalDigest(a));
        vm.expectRevert(TopUpDest.InvalidCosignature.selector);
        submit(a, abi.encodePacked(r, s, v));
    }

    function test_malformedSignatureRejected() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        vm.expectRevert(TopUpDest.InvalidCosignature.selector);
        submit(a, hex"1234");
    }

    function test_destinationChainBound() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        bytes memory sig = sign(dest, a);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(TopUpDest.InvalidCosignature.selector);
        submit(a, sig);
    }

    function test_destinationContractBound() public {
        enable();
        TopUpDest other = TopUpDest(payable(address(new UUPSProxy(address(new TopUpDest(provider, address(1))), abi.encodeCall(TopUpDest.initialize, (address(registry)))))));
        other.configureCosigner(vm.addr(SIGNER_KEY), true);
        TopUpDest.TopUpApproval memory a = approval();
        bytes memory sig = sign(dest, a);
        vm.expectRevert(TopUpDest.InvalidCosignature.selector);
        vm.prank(worker);
        other.topUpUserSafeWithApproval(a, sig);
    }

    function test_rotationAndRestoringKeyInvalidateOldApprovals() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        bytes memory sig = sign(dest, a);
        dest.configureCosigner(vm.addr(123), true);
        dest.configureCosigner(vm.addr(SIGNER_KEY), true);
        vm.expectRevert(TopUpDest.InvalidCosignature.selector);
        submit(a, sig);
        submit(a, sign(dest, a));
    }

    function test_emergencyDisableDoesNotResetCompletions() public {
        enable();
        dest.configureCosigner(vm.addr(SIGNER_KEY), false);
        vm.expectRevert(TopUpDest.TopUpAlreadyProcessed.selector);
        vm.prank(worker);
        dest.topUpUserSafe(OLD_TX, user, 1, address(token), 10 ether);
        vm.prank(worker);
        dest.topUpUserSafe(keccak256("emergency"), user, 1, address(token), 1 ether);
    }

    function test_signedRouteStillVerifiesWhenDisabled() public {
        dest.configureCosigner(vm.addr(SIGNER_KEY), false);
        TopUpDest.TopUpApproval memory a = approval();
        vm.expectRevert(TopUpDest.InvalidCosignature.selector);
        submit(a, "");
        submit(a, sign(dest, a));
    }

    function test_noSignerCannotApproveOrEnable() public {
        TopUpDest.TopUpApproval memory a = approval();
        vm.expectRevert(TopUpDest.InvalidCosigner.selector);
        submit(a, "");
        vm.expectRevert(TopUpDest.InvalidCosigner.selector);
        dest.configureCosigner(address(0), true);
    }

    function test_workerCannotConfigure() public {
        vm.expectRevert(RoleRegistry.OnlyAdminTimelock.selector);
        vm.prank(worker);
        dest.configureCosigner(address(123), false);
    }

    function test_validSignatureDoesNotReplaceWorkerRole() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        bytes memory sig = sign(dest, a);
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        dest.topUpUserSafeWithApproval(a, sig);
    }

    function test_pauseStillBlocksApprovedPayout() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        bytes memory sig = sign(dest, a);
        dest.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        submit(a, sig);
    }

    function test_batchSuccessAndAtomicFailure() public {
        enable();
        TopUpDest.TopUpApproval[] memory list = new TopUpDest.TopUpApproval[](2);
        bytes[] memory sigs = new bytes[](2);
        list[0] = approval();
        list[1] = approval();
        list[1].txHash = keccak256("second");
        sigs[0] = sign(dest, list[0]);
        sigs[1] = sign(dest, list[1]);
        list[1].amount++;
        vm.expectRevert(TopUpDest.InvalidCosignature.selector);
        vm.prank(worker);
        dest.topUpUserSafeBatchWithApproval(list, sigs);
        assertFalse(dest.isTransactionCompleted(list[0].txHash, user, address(token)));
        assertEq(token.balanceOf(user), 1 ether);
        list[1].amount--;
        vm.prank(worker);
        dest.topUpUserSafeBatchWithApproval(list, sigs);
        assertEq(token.balanceOf(user), 5 ether);
    }

    function test_batchLengthMismatch() public {
        enable();
        vm.expectRevert(TopUpDest.ArrayLengthMismatch.selector);
        vm.prank(worker);
        dest.topUpUserSafeBatchWithApproval(new TopUpDest.TopUpApproval[](1), new bytes[](0));
    }

    function test_safeAndBalanceChecksPreserved() public {
        enable();
        TopUpDest.TopUpApproval memory a = approval();
        vm.mockCall(provider, abi.encodeWithSelector(IEtherFiDataProvider.isEtherFiSafe.selector, user), abi.encode(false));
        bytes memory sig = sign(dest, a);
        vm.expectRevert(TopUpDest.NotARegisteredSafe.selector);
        submit(a, sig);
        vm.mockCall(provider, abi.encodeWithSelector(IEtherFiDataProvider.isEtherFiSafe.selector, user), abi.encode(true));
        a.amount = 1000 ether;
        sig = sign(dest, a);
        vm.expectRevert(TopUpDest.BalanceTooLow.selector);
        submit(a, sig);
        assertFalse(dest.isTransactionCompleted(a.txHash, user, address(token)));
    }

    function test_stockSharesUseSameApprovalPath() public {
        enable();
        ERC4626Mock wrapper = new ERC4626Mock(address(token));
        token.approve(address(wrapper), 10 ether);
        uint256 shares = wrapper.deposit(10 ether, address(dest));
        TopUpDest.TopUpApproval memory a = approval();
        a.token = address(wrapper);
        a.amount = shares;
        submit(a, sign(dest, a));
        assertEq(wrapper.balanceOf(user), shares);
    }

    function test_lendingCallStillRunsAfterApprovedPayout() public {
        enable();
        address cash = makeAddr("cash");
        address gateway = makeAddr("gateway");
        vm.mockCall(provider, abi.encodeWithSelector(IEtherFiDataProvider.getCashModule.selector), abi.encode(cash));
        vm.mockCall(cash, abi.encodeWithSelector(ICashModule.isLendActive.selector, user), abi.encode(true));
        vm.mockCall(cash, abi.encodeWithSelector(ICashModule.getLendGateway.selector), abi.encode(gateway));
        vm.mockCall(gateway, abi.encodeWithSelector(ILendGateway.isRegistered.selector, address(token)), abi.encode(true));
        bytes memory supply = abi.encodeWithSelector(ILendGateway.supply.selector, user, address(token), 2 ether);
        vm.mockCall(gateway, supply, abi.encode(uint256(0)));
        TopUpDest.TopUpApproval memory a = approval();
        bytes memory sig = sign(dest, a);
        vm.expectCall(gateway, supply);
        submit(a, sig);
        vm.expectRevert(TopUpDest.OnlySelf.selector);
        dest.supplyTopUpToLend(user, address(token), 2 ether);
    }
}
