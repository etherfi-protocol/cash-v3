// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { OFTCrossChainSetup } from "./OFTCrossChainSetup.t.sol";

/**
 * @title OFTRoundTripTest
 * @notice End-to-end lock -> mint -> burn -> unlock over the real LZ harness, asserting
 *         amounts match exactly across 6 / 8 / 18-decimal underlyings and that the lock/mint
 *         conservation (adapter locked == shadow totalSupply) holds at every step.
 */
contract OFTRoundTripTest is OFTCrossChainSetup {
    // ----------------------------------------------------------------- lock -> mint (outbound)

    function _assertLockMint(uint8 decimals) internal {
        _deployPair(decimals);
        uint256 amount = 1234 * (10 ** decimals); // a clean (dust-free) amount
        underlying.mint(alice, amount);

        assertEq(shadow.totalSupply(), 0);
        assertEq(_locked(), 0);

        (uint256 sent, uint256 received) = _bridgeOut(alice, amount);

        assertEq(sent, amount, "sent != amount");
        assertEq(received, amount, "received != amount");
        assertEq(underlying.balanceOf(alice), 0, "underlying not pulled");
        assertEq(_locked(), amount, "adapter did not lock full amount");
        assertEq(shadow.balanceOf(alice), amount, "iTOKEN not minted 1:1");
        assertEq(shadow.totalSupply(), amount, "supply != minted");
        assertEq(_locked(), shadow.totalSupply(), "locked != minted");
    }

    function test_lockMint_6dec() public {
        _assertLockMint(6);
    }

    function test_lockMint_8dec() public {
        _assertLockMint(8);
    }

    function test_lockMint_18dec() public {
        _assertLockMint(18);
    }

    // ----------------------------------------------------------------- full round trip

    function _assertRoundTrip(uint8 decimals) internal {
        _deployPair(decimals);
        uint256 amount = 777 * (10 ** decimals);
        underlying.mint(alice, amount);

        // out: lock on mainnet, mint on OP
        _bridgeOut(alice, amount);
        assertEq(_locked(), shadow.totalSupply());

        // back: burn on OP, unlock on mainnet
        (uint256 sentBack, uint256 receivedBack) = _bridgeBack(alice, amount);
        assertEq(sentBack, amount);
        assertEq(receivedBack, amount);

        // user is whole again; nothing left locked or minted
        assertEq(underlying.balanceOf(alice), amount, "user not made whole");
        assertEq(shadow.balanceOf(alice), 0, "iTOKEN not burned");
        assertEq(shadow.totalSupply(), 0, "supply not zero after burn");
        assertEq(_locked(), 0, "adapter still holds underlying");
        assertEq(_locked(), shadow.totalSupply());
    }

    function test_roundTrip_6dec() public {
        _assertRoundTrip(6);
    }

    function test_roundTrip_8dec() public {
        _assertRoundTrip(8);
    }

    function test_roundTrip_18dec() public {
        _assertRoundTrip(18);
    }

    // ----------------------------------------------------------------- fuzz: value conservation

    /**
     * End-to-end fuzz over (decimals, amount): a full round trip never creates value, the bridged
     * amount is the input minus dust, sub-rate dust stays with the user, and the user is made whole.
     * Capped runs — each run deploys a fresh pair on the live endpoints, which is expensive.
     */
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_roundTrip_conservesValue(uint8 decimals, uint256 amount) public {
        decimals = uint8(bound(decimals, SHARED_DECIMALS, 18));
        uint256 rate = 10 ** (decimals - SHARED_DECIMALS);
        // up to 1e9 tokens — well under the uint64 SD ceiling, and mintable
        amount = bound(amount, 0, 1e9 * (10 ** uint256(decimals)));

        _deployPair(decimals);
        underlying.mint(alice, amount);

        uint256 expectedBridged = (amount / rate) * rate; // dust removed
        if (expectedBridged == 0) {
            // sub-rate: nothing bridgeable. The pure dust math is covered in OFTDecimals.fuzz.
            return;
        }

        (uint256 sent, uint256 received) = _bridgeOut(alice, amount);
        assertEq(sent, expectedBridged, "sent != dust-removed amount");
        assertEq(received, expectedBridged, "received != sent (value created/destroyed)");
        assertLe(received, amount, "round-trip created value");
        assertEq(underlying.balanceOf(alice), amount - expectedBridged, "dust not left with user");
        assertEq(shadow.totalSupply(), expectedBridged);
        assertEq(_locked(), shadow.totalSupply());

        (uint256 sentBack, uint256 receivedBack) = _bridgeBack(alice, expectedBridged);
        assertEq(sentBack, expectedBridged);
        assertEq(receivedBack, expectedBridged);
        assertEq(underlying.balanceOf(alice), amount, "user not made whole (dust + principal)");
        assertEq(_locked(), 0);
        assertEq(shadow.totalSupply(), 0);
    }

    // A partial round trip: bridge out, then bridge back only part — conservation still holds.
    function test_partialBridgeBack_conservationHolds() public {
        _deployPair(8);
        uint256 amount = 1000e8;
        underlying.mint(alice, amount);

        _bridgeOut(alice, amount);
        assertEq(_locked(), shadow.totalSupply());

        uint256 half = 400e8;
        _bridgeBack(alice, half);

        assertEq(shadow.balanceOf(alice), amount - half);
        assertEq(shadow.totalSupply(), amount - half);
        assertEq(_locked(), amount - half);
        assertEq(underlying.balanceOf(alice), half);
        assertEq(_locked(), shadow.totalSupply());
    }
}
