// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";

import { OFTCrossChainSetup } from "./OFTCrossChainSetup.t.sol";
import { IPacketVerifier, OFTConservationHandler } from "./handlers/OFTConservationHandler.sol";

/**
 * @title OFTConservationInvariantTest
 * @notice Handler-based stateful invariant. The handler drives randomized bridgeOut/bridgeBack
 *         sequences over the live LZ harness (each delivering its packet synchronously), and after
 *         every call the core conservation invariant is re-checked: the underlying locked in the
 *         mainnet adapter must always equal the iTOKEN supply minted on OP (same decimals -> 1:1).
 */
contract OFTConservationInvariantTest is OFTCrossChainSetup {
    OFTConservationHandler internal handler;

    function setUp() public override {
        super.setUp();
        _deployPair(8); // WBTC-like precision; conservation is decimals-agnostic, one pair suffices

        address[] memory users = new address[](3);
        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");

        handler = new OFTConservationHandler(IPacketVerifier(address(this)), adapter, shadow, underlying, A_EID, B_EID, users);

        // Only fuzz the two bridge actions on the handler.
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = OFTConservationHandler.bridgeOut.selector;
        selectors[1] = OFTConservationHandler.bridgeBack.selector;
        targetSelector(StdInvariant.FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// @notice locked underlying (mainnet) == minted iTOKEN supply (OP), at all times.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_lockedEqualsMinted() public view {
        assertEq(underlying.balanceOf(address(adapter)), shadow.totalSupply(), "locked underlying != iTOKEN supply");
    }

    /// @notice Guards against a vacuous pass: confirm the fuzzer actually exercised the bridge path.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = true
    function afterInvariant() public view {
        assertGt(handler.bridgeOutCount(), 0, "invariant ran zero effective bridgeOut calls");
    }
}
