// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StdInvariant } from "forge-std/StdInvariant.sol";

import { OFTCrossChainSetup } from "./OFTCrossChainSetup.t.sol";
import { IPacketVerifier, OFTConservationHandler } from "./handlers/OFTConservationHandler.sol";

/**
 * @title OFTConservationInvariantTest
 * @notice Handler-based stateful invariant across the supported decimal range. For each of three
 *         pairs (6-, 8-, and 18-decimal underlyings) a handler drives randomized bridgeOut/bridgeBack
 *         sequences over the live LZ harness (each delivering its packet synchronously), and after
 *         every call the conservation invariant is re-checked for EVERY pair: the underlying locked
 *         in the mainnet adapter must always equal the iTOKEN supply minted on OP (same decimals ->
 *         1:1). Spanning 6/8/18 decimals proves the dust/SD scaling preserves conservation at the
 *         precision extremes, not just at the WBTC-like 8-decimal midpoint.
 */
contract OFTConservationInvariantTest is OFTCrossChainSetup {
    OFTConservationHandler[] internal handlers;

    function setUp() public override {
        super.setUp();

        address[] memory users = new address[](3);
        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");

        // Only fuzz the two bridge actions on each handler.
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = OFTConservationHandler.bridgeOut.selector;
        selectors[1] = OFTConservationHandler.bridgeBack.selector;

        uint8[3] memory decimalsList = [uint8(6), 8, 18];
        for (uint256 i; i < decimalsList.length; ++i) {
            _deployPair(decimalsList[i]); // sets adapter/shadow/underlying to this pair
            OFTConservationHandler handler =
                new OFTConservationHandler(IPacketVerifier(address(this)), adapter, shadow, underlying, A_EID, B_EID, users);
            handlers.push(handler);

            targetSelector(StdInvariant.FuzzSelector({ addr: address(handler), selectors: selectors }));
            targetContract(address(handler));
        }
    }

    /// @notice For every pair: locked underlying (mainnet) == minted iTOKEN supply (OP), at all times.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_lockedEqualsMinted() public view {
        for (uint256 i; i < handlers.length; ++i) {
            OFTConservationHandler h = handlers[i];
            assertEq(h.underlying().balanceOf(address(h.adapter())), h.shadow().totalSupply(), "locked underlying != iTOKEN supply");
        }
    }

    /// @notice Guards against a vacuous pass: confirm the fuzzer actually exercised the bridge path.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 30
    /// forge-config: default.invariant.fail-on-revert = true
    function afterInvariant() public view {
        uint256 totalBridgeOut;
        for (uint256 i; i < handlers.length; ++i) {
            totalBridgeOut += handlers[i].bridgeOutCount();
        }
        assertGt(totalBridgeOut, 0, "invariant ran zero effective bridgeOut calls");
    }
}
