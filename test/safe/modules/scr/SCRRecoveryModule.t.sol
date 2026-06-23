// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { SafeTestSetup, UUPSProxy } from "../../SafeTestSetup.t.sol";
import { SCRRecoveryModule } from "../../../../src/modules/scr/SCRRecoveryModule.sol";
import { MockERC20 } from "../../../../src/mocks/MockERC20.sol";

contract SCRRecoveryModuleTest is SafeTestSetup {
    SCRRecoveryModule public scrModule;
    MockERC20 public scr;

    // Hardcoded SCR token address on Scroll (must match the contract constant)
    address public constant SCR_ADDR = 0xd29687c813D741E2F938F4aC377128810E217b1b;

    address public collectionWallet = makeAddr("collectionWallet");
    bytes32 public SCR_RECOVERY_ADMIN_ROLE = keccak256("SCR_RECOVERY_ADMIN_ROLE");

    uint256 public scrBalance = 1000 ether;

    function setUp() public override {
        super.setUp();

        // Place a mock ERC20 at the hardcoded SCR address so we can mint/transfer in tests
        vm.etch(SCR_ADDR, address(new MockERC20("Scroll", "SCR", 18)).code);
        scr = MockERC20(SCR_ADDR);

        vm.startPrank(owner);

        address impl = address(new SCRRecoveryModule(address(dataProvider)));
        scrModule = SCRRecoveryModule(
            address(
                new UUPSProxy(
                    impl,
                    abi.encodeWithSelector(SCRRecoveryModule.initialize.selector, address(roleRegistry), collectionWallet)
                )
            )
        );

        // Register as a default module so it is enabled on every safe
        address[] memory modules = new address[](1);
        modules[0] = address(scrModule);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        dataProvider.configureDefaultModules(modules, shouldWhitelist);

        roleRegistry.grantRole(SCR_RECOVERY_ADMIN_ROLE, owner);

        vm.stopPrank();

        // Seed the safe with SCR
        scr.mint(address(safe), scrBalance);
    }

    // ─────────────────────────────────────────────────────────────
    //                         CONFIG
    // ─────────────────────────────────────────────────────────────

    function test_initialize_setsConfig() public view {
        assertEq(address(scrModule.dataProvider()), address(dataProvider));
        assertEq(address(scrModule.scr()), SCR_ADDR);
        assertEq(scrModule.collectionWallet(), collectionWallet);
    }

    function test_setCollectionWallet_byAdmin() public {
        address newWallet = makeAddr("newWallet");

        vm.expectEmit(true, true, true, true);
        emit SCRRecoveryModule.CollectionWalletSet(newWallet);

        vm.prank(owner);
        scrModule.setCollectionWallet(newWallet);

        assertEq(scrModule.collectionWallet(), newWallet);
    }

    function test_setCollectionWallet_revertsForNonAdmin() public {
        vm.prank(notOwner);
        vm.expectRevert(SCRRecoveryModule.OnlyAdmin.selector);
        scrModule.setCollectionWallet(makeAddr("x"));
    }

    function test_setCollectionWallet_revertsForZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SCRRecoveryModule.InvalidInput.selector);
        scrModule.setCollectionWallet(address(0));
    }

    // ─────────────────────────────────────────────────────────────
    //                         COLLECT
    // ─────────────────────────────────────────────────────────────

    function test_collect_movesScrToCollectionWallet() public {
        address[] memory safes = new address[](1);
        safes[0] = address(safe);

        vm.expectEmit(true, true, true, true);
        emit SCRRecoveryModule.SCRCollected(address(safe), scrBalance, collectionWallet);

        vm.prank(etherFiWallet);
        scrModule.collect(safes);

        assertEq(scr.balanceOf(address(safe)), 0);
        assertEq(scr.balanceOf(collectionWallet), scrBalance);
    }

    function test_collect_secondCallOnDrainedSafeIsNoop() public {
        address[] memory safes = new address[](1);
        safes[0] = address(safe);

        vm.prank(etherFiWallet);
        scrModule.collect(safes);

        // Safe now holds no SCR; a second collect should be a no-op
        vm.prank(etherFiWallet);
        scrModule.collect(safes);

        assertEq(scr.balanceOf(collectionWallet), scrBalance);
        assertEq(scr.balanceOf(address(safe)), 0);
    }

    function test_collect_skipsZeroBalanceSafe() public {
        // Drain the safe first
        address[] memory safes = new address[](1);
        safes[0] = address(safe);
        vm.prank(etherFiWallet);
        scrModule.collect(safes);

        // Deploy a fresh safe with no SCR
        address freshSafe = _deploySafe(keccak256("freshSafe"));

        address[] memory freshOnly = new address[](1);
        freshOnly[0] = freshSafe;

        vm.prank(etherFiWallet);
        scrModule.collect(freshOnly);

        assertEq(scr.balanceOf(collectionWallet), scrBalance);
    }

    function test_collect_batchMultipleSafes() public {
        address safe2 = _deploySafe(keccak256("safe2"));
        scr.mint(safe2, 250 ether);

        address[] memory safes = new address[](2);
        safes[0] = address(safe);
        safes[1] = safe2;

        vm.prank(etherFiWallet);
        scrModule.collect(safes);

        assertEq(scr.balanceOf(collectionWallet), scrBalance + 250 ether);
        assertEq(scr.balanceOf(address(safe)), 0);
        assertEq(scr.balanceOf(safe2), 0);
    }

    // ─────────────────────────────────────────────────────────────
    //                         REVERTS
    // ─────────────────────────────────────────────────────────────

    function test_collect_revertsForNonEtherFiWallet() public {
        address[] memory safes = new address[](1);
        safes[0] = address(safe);

        vm.prank(notOwner);
        vm.expectRevert(SCRRecoveryModule.OnlyEtherFiWallet.selector);
        scrModule.collect(safes);
    }

    function test_collect_revertsForEmptyArray() public {
        address[] memory safes = new address[](0);

        vm.prank(etherFiWallet);
        vm.expectRevert(SCRRecoveryModule.InvalidInput.selector);
        scrModule.collect(safes);
    }

    function test_collect_revertsForNonSafe() public {
        address[] memory safes = new address[](1);
        safes[0] = makeAddr("notASafe");

        vm.prank(etherFiWallet);
        vm.expectRevert(SCRRecoveryModule.NotEtherFiSafe.selector);
        scrModule.collect(safes);
    }

    function test_initialize_revertsForZeroCollectionWallet() public {
        address impl = address(new SCRRecoveryModule(address(dataProvider)));

        vm.expectRevert(SCRRecoveryModule.InvalidInput.selector);
        new UUPSProxy(
            impl,
            abi.encodeWithSelector(SCRRecoveryModule.initialize.selector, address(roleRegistry), address(0))
        );
    }

    function test_constructor_revertsForZeroAddress() public {
        vm.expectRevert(SCRRecoveryModule.InvalidInput.selector);
        new SCRRecoveryModule(address(0));
    }

    // ─────────────────────────────────────────────────────────────
    //                         HELPERS
    // ─────────────────────────────────────────────────────────────

    function _deploySafe(bytes32 salt) internal returns (address) {
        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        address[] memory modules = new address[](2);
        modules[0] = module1;
        modules[1] = module2;
        bytes[] memory moduleSetupData = new bytes[](2);

        vm.prank(owner);
        safeFactory.deployEtherFiSafe(salt, owners, modules, moduleSetupData, threshold);
        return safeFactory.getDeterministicAddress(salt);
    }
}
