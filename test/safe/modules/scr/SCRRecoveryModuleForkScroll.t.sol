// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { SCRRecoveryModule } from "../../../../src/modules/scr/SCRRecoveryModule.sol";
import { IRoleRegistry } from "../../../../src/interfaces/IRoleRegistry.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { EtherFiDataProvider } from "../../../../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiHook } from "../../../../src/hook/EtherFiHook.sol";

/**
 * @title SCRRecoveryModuleForkScrollTest
 * @notice Fork test against live Scroll mainnet state. Verifies that SCR can be
 *         recovered from a real, indebted user safe whose collateral oracle is stale,
 *         once the EtherFiHook is configured to bypass the health check for the
 *         SCRRecoveryModule.
 * @dev Requires SCROLL_RPC. Block is pinned so the test is deterministic.
 */
contract SCRRecoveryModuleForkScrollTest is Test {
    // ── Live Scroll mainnet deployments ──
    address constant DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant ROLE_REGISTRY = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address constant DEBT_MANAGER  = 0x0078C5a459132e279056B2371fE8A8eC973A9553;
    address constant SCR           = 0xd29687c813D741E2F938F4aC377128810E217b1b;

    // Owner of the RoleRegistry (cash controller safe) — used to wire up roles
    address constant ROLE_REGISTRY_OWNER = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // A real user safe on Scroll that holds SCR and carries outstanding debt
    address constant USER_SAFE = 0x833E2DbaB15A63B8a7A14c23DB683B97c9Fe6eC5;

    // Pinned block so the SCR balance / debt state is deterministic
    uint256 constant FORK_BLOCK = 33916290;

    bytes32 constant ETHER_FI_WALLET_ROLE = keccak256("ETHER_FI_WALLET_ROLE");
    bytes32 constant DATA_PROVIDER_ADMIN_ROLE = keccak256("DATA_PROVIDER_ADMIN_ROLE");

    SCRRecoveryModule module;
    EtherFiHook hook;
    IERC20 scr = IERC20(SCR);
    address collectionWallet = makeAddr("collectionWallet");
    address etherFiWallet = makeAddr("etherFiWallet");

    function setUp() public {
        vm.createSelectFork("scroll", FORK_BLOCK);

        // Deploy the module against the live data provider + role registry
        address impl = address(new SCRRecoveryModule(DATA_PROVIDER));
        module = SCRRecoveryModule(
            address(
                new UUPSProxy(
                    impl,
                    abi.encodeWithSelector(SCRRecoveryModule.initialize.selector, ROLE_REGISTRY, collectionWallet)
                )
            )
        );

        // Deploy the new EtherFiHook (with the SCR recovery bypass) and point the data
        // provider at it — mirrors the upgrade that will ship to Scroll
        address hookImpl = address(new EtherFiHook(DATA_PROVIDER));
        hook = EtherFiHook(
            address(new UUPSProxy(hookImpl, abi.encodeWithSelector(EtherFiHook.initialize.selector, ROLE_REGISTRY)))
        );

        // Acting as the registry owner: wire up hook, default module, wallet role, and bypass
        vm.startPrank(ROLE_REGISTRY_OWNER);

        IRoleRegistry(ROLE_REGISTRY).grantRole(DATA_PROVIDER_ADMIN_ROLE, ROLE_REGISTRY_OWNER);
        EtherFiDataProvider(DATA_PROVIDER).setHookAddress(address(hook));

        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        EtherFiDataProvider(DATA_PROVIDER).configureDefaultModules(modules, shouldWhitelist);

        IRoleRegistry(ROLE_REGISTRY).grantRole(ETHER_FI_WALLET_ROLE, etherFiWallet);

        hook.setScrRecoveryModule(address(module));

        vm.stopPrank();
    }

    function test_collect_pullsScrFromIndebtedSafe() public {
        // Sanity: at the pinned block this safe holds SCR and is indebted
        uint256 balanceBefore = scr.balanceOf(USER_SAFE);
        assertGt(balanceBefore, 0, "safe should hold SCR at pinned block");

        (, uint256 debt) = IDebtManager(DEBT_MANAGER).borrowingOf(USER_SAFE);
        assertGt(debt, 0, "safe should be indebted at pinned block");

        address[] memory safes = new address[](1);
        safes[0] = USER_SAFE;

        vm.prank(etherFiWallet);
        module.collect(safes);

        assertEq(scr.balanceOf(USER_SAFE), 0, "all SCR pulled from safe");
        assertEq(scr.balanceOf(collectionWallet), balanceBefore, "SCR received by collection wallet");
    }

    function test_collect_revertsWithoutBypass_dueToStaleOracle() public {
        // Clear the bypass so the health check runs; the safe's collateral oracle is
        // stale at this block, so ensureHealth reverts. This proves the hook bypass is
        // what makes the recovery work on the deprecated chain.
        vm.prank(ROLE_REGISTRY_OWNER);
        hook.setScrRecoveryModule(address(0));

        address[] memory safes = new address[](1);
        safes[0] = USER_SAFE;

        vm.prank(etherFiWallet);
        vm.expectRevert();
        module.collect(safes);
    }
}
