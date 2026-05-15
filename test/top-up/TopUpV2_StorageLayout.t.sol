// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";

/**
 * @title TopUpV2_StorageLayoutTest
 * @notice Catches storage-layout regressions between `TopUp` (v1) and `TopUpV2` (the new beacon
 *         impl). The beacon upgrade swaps the impl bytecode under existing per-user TopUp
 *         proxies; if v2 reorders or adds a non-immutable storage slot, every existing user
 *         could lose ownership or have their `owner()` corrupted.
 *
 *         v1 has zero non-immutable storage of its own — it only uses Solady's Ownable slot at
 *         `0xffff...74873927`. v2 adds only `address public immutable DISPATCHER` (immutables
 *         live in code, not storage) plus functions/events. Therefore v2 must read the same
 *         Solady owner slot and add NO new storage variables.
 *
 * @dev Approach: deploy v1, capture `owner()` and the raw storage slot. Etch v2 bytecode over
 *      the same address and confirm `owner()` still returns the same value via the same slot.
 *      A snapshot of `forge inspect TopUp(V2) storage-layout` would catch a wider class of
 *      regressions; track that here and pin the smallest no-regression invariant we can run
 *      cheaply in-process.
 *
 *      // TODO: snapshot via `forge inspect TopUp storage-layout` and `forge inspect TopUpV2
 *      //       storage-layout` and diff — manual command:
 *      //         forge inspect TopUp storage-layout > /tmp/topup-v1.json
 *      //         forge inspect TopUpV2 storage-layout > /tmp/topup-v2.json
 *      //         diff /tmp/topup-v1.json /tmp/topup-v2.json
 *      //       Diff must be empty (both have no non-immutable storage).
 */
contract TopUpV2_StorageLayoutTest is Test {
    /// @dev Solady Ownable's hashed owner slot — see `lib/solady/src/auth/Ownable.sol`.
    bytes32 internal constant SOLADY_OWNER_SLOT =
        0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927;

    address internal weth = makeAddr("weth");
    address internal dispatcher = makeAddr("dispatcher");

    function test_v2_preservesOwnerSlotFromV1() public {
        // 1. Deploy v1 and pin the recorded owner — v1's ctor sets `owner()` to 0xdead.
        TopUp v1 = new TopUp(weth);
        address v1Owner = v1.owner();
        assertEq(v1Owner, address(0xdead), "v1 owner should be 0xdead");
        bytes32 v1Slot = vm.load(address(v1), SOLADY_OWNER_SLOT);
        assertEq(uint256(v1Slot), uint256(uint160(v1Owner)), "v1 slot mismatch");

        // 2. Etch v2 bytecode over v1's address. We rely on Foundry's `vm.etch` here rather than
        //    a real beacon-proxy upgrade so the test stays self-contained — the invariant we
        //    care about is purely about the storage layout being byte-identical.
        TopUpV2 v2Impl = new TopUpV2(weth, dispatcher);
        vm.etch(address(v1), address(v2Impl).code);

        // 3. Same address, v2 logic — `owner()` must still resolve from the same slot.
        TopUpV2 etched = TopUpV2(payable(address(v1)));
        assertEq(etched.owner(), v1Owner, "owner() must survive impl swap");
        assertEq(
            uint256(vm.load(address(etched), SOLADY_OWNER_SLOT)),
            uint256(uint160(v1Owner)),
            "slot value drift"
        );

        // 4. v2 must NOT have written any new storage in slot 0..3 (sanity probe — `DISPATCHER`
        //    is an immutable so it lives in code, not storage).
        for (uint256 slot = 0; slot < 4; slot++) {
            assertEq(uint256(vm.load(address(etched), bytes32(slot))), 0, "unexpected storage write in v2");
        }
    }

    function test_v2_initializeFlowSetsOwnerInSameSlot() public {
        // Mirrors the prod beacon-proxy flow: deploy proxy → call initialize(factory) → owner()
        // resolves from the Solady slot. We use `vm.etch` again to keep the test pure-EVM, then
        // call `initialize` — note that `initialize` reads the slot via `owner() != 0` to gate.
        TopUp v1 = new TopUp(weth);
        TopUpV2 v2Impl = new TopUpV2(weth, dispatcher);

        // Reset the proxy's owner slot to zero so `initialize` is allowed to run.
        vm.store(address(v1), SOLADY_OWNER_SLOT, bytes32(0));
        vm.etch(address(v1), address(v2Impl).code);

        address newOwner = makeAddr("factory");
        TopUpV2(payable(address(v1))).initialize(newOwner);

        assertEq(TopUpV2(payable(address(v1))).owner(), newOwner, "v2 owner");
        assertEq(
            uint256(vm.load(address(v1), SOLADY_OWNER_SLOT)),
            uint256(uint160(newOwner)),
            "v2 wrote owner to the same Solady slot as v1"
        );
    }
}
