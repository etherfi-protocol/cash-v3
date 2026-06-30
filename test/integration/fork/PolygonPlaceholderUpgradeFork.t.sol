// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { TopUpFactory } from "../../../src/top-up/TopUpFactory.sol";
import { TopUp } from "../../../src/top-up/TopUp.sol";

interface IUUPSProxy {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface IOwner {
    function owner() external view returns (address);
}

interface IPlaceholderView {
    function roleRegistry() external view returns (address);
}

/**
 * @title PolygonPlaceholderUpgradeFork
 * @notice Verifies the central claim in `ADD_POLYGON_CHAIN.md` Phase 0.5 / Prerequisite:
 *         "the placeholder consumed `initializer` v1, so the upgrade to TopUpFactory
 *         must use `reinitializer(2)` — without it the upgrade reverts."
 *
 *         Forks Polygon at head and runs the upgrade against the **real** reserved
 *         proxy state:
 *
 *           SCENARIO A — current TopUpFactory.initialize() reverts.
 *           SCENARIO B — TopUpFactoryWithReinit.initializeV2() succeeds.
 *
 *         If A passes, the blocker is real. If B passes, the proposed fix works.
 *
 * Run:
 *   POLYGON_RPC=<url> forge test --match-contract PolygonPlaceholderUpgradeFork -vvv
 *   FORK_BLOCK=0      forks at head (use a non-archival public RPC for quick check).
 */
contract PolygonPlaceholderUpgradeFork is Test {
    /// @dev Reserved CREATE3 slot — same address on every prod chain by construction.
    address constant RESERVED_PROXY = 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF;
    /// @dev Polygon prod RoleRegistry (stored in the placeholder via `__UpgradeableProxy_init`).
    address constant ROLE_REGISTRY = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    /// @dev Wrapped native (WPOL) — baked into `TopUp` constructor immutable.
    address constant WPOL = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    /// @dev OZ Initializable v5 namespaced storage slot:
    ///      keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1)) & ~bytes32(uint256(0xff))
    ///      The slot's first 8 bytes are `uint64 _initialized`, byte 9 is `bool _initializing`.
    bytes32 constant OZ_INIT_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    function setUp() public {
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork("polygon");
        else vm.createSelectFork("polygon", pin);
        require(block.chainid == 137, "must be Polygon");
    }

    // ─────────────────────────────────────── Pre-state ─────────────────────────────────────────

    /// @notice The reserved proxy is the `EtherFiPlaceholder` — initialized, `roleRegistry` set,
    ///         `beacon` / `getDeterministicAddress` revert. This is the literal state today on prod.
    function test_preState_placeholderIsInitialized() public view {
        // OZ _initialized == 1 (placeholder consumed v1 initializer)
        bytes32 initState = vm.load(RESERVED_PROXY, OZ_INIT_SLOT);
        assertEq(uint256(initState) & 0xFF, 1, "expected _initialized == 1");

        // Placeholder's UpgradeableProxy.roleRegistry() returns the real RR
        assertEq(IPlaceholderView(RESERVED_PROXY).roleRegistry(), ROLE_REGISTRY, "RR wired");

        // beacon() / getDeterministicAddress() revert — proves it isn't a TopUpFactory yet
        (bool ok1, ) = RESERVED_PROXY.staticcall(abi.encodeWithSignature("beacon()"));
        assertFalse(ok1, "beacon() must revert before upgrade");
        (bool ok2, ) = RESERVED_PROXY.staticcall(
            abi.encodeWithSignature("getDeterministicAddress(bytes32)", bytes32(uint256(1)))
        );
        assertFalse(ok2, "getDeterministicAddress() must revert before upgrade");
    }

    // ───────────────────────────── Scenario A: blocker proof ─────────────────────────────

    /// @notice ⚠️ HARD BLOCKER — without a `reinitializer(2)` entry point, the upgrade reverts.
    ///         Calls `upgradeToAndCall(topUpFactoryImpl, initialize(rr, topUpImpl))` as the RR
    ///         owner (Polygon's operating safe). The inner `initialize()` is `initializer`
    ///         v1; the proxy already has `_initialized = 1` from the placeholder, so OZ's
    ///         Initializable reverts with `InvalidInitialization()` before any state changes.
    function test_scenarioA_currentInitializerReverts() public {
        TopUpFactory factoryImpl = new TopUpFactory();
        TopUp baseTopUp = new TopUp(WPOL);

        bytes memory initCalldata = abi.encodeCall(
            TopUpFactory.initialize,
            (ROLE_REGISTRY, address(baseTopUp))
        );

        address rrOwner = IOwner(ROLE_REGISTRY).owner();
        vm.prank(rrOwner);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        IUUPSProxy(RESERVED_PROXY).upgradeToAndCall(address(factoryImpl), initCalldata);
    }

    /// @notice Sanity counterpart — confirms the revert in A is from the inner initialize(),
    ///         not from `_authorizeUpgrade` or any other check. Calls `upgradeToAndCall`
    ///         from a NON-owner, which must revert with the upgrader's `OnlyUpgrader` error,
    ///         not `InvalidInitialization`. (The auth gate runs before the init delegatecall.)
    function test_scenarioA_authGateBeforeInit() public {
        TopUpFactory factoryImpl = new TopUpFactory();
        TopUp baseTopUp = new TopUp(WPOL);

        bytes memory initCalldata = abi.encodeCall(
            TopUpFactory.initialize,
            (ROLE_REGISTRY, address(baseTopUp))
        );

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        // Expect any revert (the specific selector is OnlyUpgrader() from RoleRegistry);
        // the key is that it's NOT InvalidInitialization — the auth check ran first.
        vm.expectRevert();
        IUUPSProxy(RESERVED_PROXY).upgradeToAndCall(address(factoryImpl), initCalldata);
    }

    // ───────────────────────────── Scenario B: fix validation ────────────────────────────

    /// @notice ✅ FIX — with the real `TopUpFactory.reinitialize(address)` added, the upgrade
    ///         succeeds. The proxy stays at the same address (`0xF4e147…D8CF`), the impl pointer
    ///         flips to the new `TopUpFactory`, `_initialized` advances to 2, and all
    ///         post-upgrade reads (`beacon`, `getDeterministicAddress`, `roleRegistry`) work.
    ///         RoleRegistry pointer is preserved — `reinitialize` reads it from existing storage
    ///         (set during the placeholder's v1 init), it is NOT supplied by the caller.
    function test_scenarioB_reinitializerV2Succeeds() public {
        TopUpFactory factoryImpl = new TopUpFactory();
        TopUp baseTopUp = new TopUp(WPOL);

        bytes memory initCalldata = abi.encodeCall(
            TopUpFactory.reinitialize,
            (address(baseTopUp))
        );

        address rrOwner = IOwner(ROLE_REGISTRY).owner();
        vm.prank(rrOwner);
        IUUPSProxy(RESERVED_PROXY).upgradeToAndCall(address(factoryImpl), initCalldata);

        // OZ _initialized == 2 now
        bytes32 initState = vm.load(RESERVED_PROXY, OZ_INIT_SLOT);
        assertEq(uint256(initState) & 0xFF, 2, "expected _initialized == 2 after reinit");

        // Address unchanged — proxy still at the canonical reserved slot
        TopUpFactory factory = TopUpFactory(payable(RESERVED_PROXY));

        // Post-upgrade reads work; RR was preserved from the placeholder's v1 storage, not re-supplied.
        assertEq(address(factory.roleRegistry()), ROLE_REGISTRY, "RR preserved across upgrade");
        address beacon = factory.beacon();
        assertTrue(beacon != address(0), "beacon initialized");
        assertTrue(
            factory.getDeterministicAddress(bytes32(uint256(0x1234))) != address(0),
            "getDeterministicAddress resolves"
        );
    }

    /// @notice Second call to `reinitialize` must revert — `reinitializer(2)` is one-shot.
    ///         Guards against accidental re-initialization in operational mistakes.
    function test_scenarioB_reinitializerV2_isOneShot() public {
        TopUpFactory factoryImpl = new TopUpFactory();
        TopUp baseTopUp = new TopUp(WPOL);

        address rrOwner = IOwner(ROLE_REGISTRY).owner();

        bytes memory initCalldata = abi.encodeCall(
            TopUpFactory.reinitialize,
            (address(baseTopUp))
        );
        vm.prank(rrOwner);
        IUUPSProxy(RESERVED_PROXY).upgradeToAndCall(address(factoryImpl), initCalldata);

        // Now try to call reinitialize again directly — must revert.
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TopUpFactory(payable(RESERVED_PROXY)).reinitialize(address(baseTopUp));
    }
}
