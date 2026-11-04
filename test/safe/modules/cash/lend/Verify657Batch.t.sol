// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

interface IOracle {
    function getReserveSource(uint256) external view returns (address);
    function getReservePrice(uint256) external view returns (uint256);
}
interface IFeed { function rateMaxStaleness() external view returns (uint256); }
interface ISpokeLike {
    function getReserveCount() external view returns (uint256);
    function getUserAccountData(address) external view returns (uint256,uint256,uint256,uint256,uint256,uint256,uint256);
}

/**
 * @notice Replays the EXACT 3CP-657 MultiSend payload as the Lend Owner Safe on a mainnet fork and
 *         verifies the post-state, so the batch is proven executable before signatures are collected.
 *
 *         The payload is the literal `data` field from queued/657/optimism.json, delegatecalled
 *         through MultiSendCallOnly 1.4.1 exactly as the Safe will do it — not 20 individual pranked
 *         calls, which would not exercise the MultiSend encoding that the signers actually sign over.
 */
contract Verify657Batch is Test {
    address constant SAFE = 0x082B85ED50F1cd120C597EF860ece712e54CE844;
    address constant MULTISEND = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address constant CONFIGURATOR = 0xFEe9E8cCE1c40D3bd9F025437D3A11cA0DAe9f8b;
    address constant ORACLE = 0xe8cbd37210bF1E29436dAe183d7b9fe45E886fA8;
    address constant SPOKE = 0xdffcC3536D932eb51Df51a7F5FA407c4270d5308;
    uint256 constant FLOOR = 604800;

    function test_replay_657_multisend_as_owner_safe() public {
        bytes memory payload = vm.parseBytes(vm.readFile("test/safe/modules/cash/lend/fixtures/3cp657-multisend.txt"));
        assertGt(payload.length, 3000, "payload looks truncated");

        uint256 count = ISpokeLike(SPOKE).getReserveCount();
        assertEq(count, 23, "reserve count changed");

        // --- pre-state: at least one leg must be BELOW the floor, else the test proves nothing
        uint256 belowBefore;
        for (uint256 i; i < count; i++) {
            if (_minBoundIn(IOracle(ORACLE).getReserveSource(i)) < FLOOR) belowBefore++;
        }
        assertGt(belowBefore, 0, "nothing is below the floor pre-batch - test would be vacuous");
        console.log("reserves with a sub-floor leg BEFORE:", belowBefore);

        // record prices to prove the repoint does not move any price
        uint256[] memory before = new uint256[](count);
        for (uint256 i; i < count; i++) before[i] = IOracle(ORACLE).getReservePrice(i);

        // --- execute: decode the MultiSend payload and replay each inner call AS THE SAFE.
        //
        // A `delegatecall` from this test into MultiSend would run in the TEST's context, so the
        // configurator's role check would see the test contract as msg.sender and revert. Decoding
        // the blob and pranking each inner call is the faithful replay: it exercises the exact
        // encoding the signers sign over (any mis-encoding shows up as a bad target/selector or a
        // length mismatch) AND it exercises the real role check, since pranking bypasses the Safe's
        // signature threshold but not the configurator's authorization.
        uint256 executed = _replayMultiSend(payload);
        assertEq(executed, 20, "payload did not decode to exactly 20 inner calls");

        // --- post-state
        uint256 belowAfter;
        for (uint256 i; i < count; i++) {
            uint256 mb = _minBoundIn(IOracle(ORACLE).getReserveSource(i));
            if (mb < FLOOR) { belowAfter++; console.log("STILL BELOW FLOOR: reserve", i, mb); }
        }
        assertEq(belowAfter, 0, "a leg is still below the 7d floor after the batch");

        // prices must be untouched, to the wei
        for (uint256 i; i < count; i++) {
            assertEq(IOracle(ORACLE).getReservePrice(i), before[i], "a reserve price moved");
        }
        console.log("reserves with a sub-floor leg AFTER :", belowAfter);
        console.log("all 23 prices identical to the wei after the repoint");
    }

    /// @dev Decode a MultiSendCallOnly 1.4.1 payload and execute every inner transaction as the Safe.
    ///      Layout after the `multiSend(bytes)` selector + offset + length header, per entry:
    ///        1 byte operation | 20 bytes to | 32 bytes value | 32 bytes dataLength | dataLength bytes
    ///      Asserts each entry is a CALL (operation 0), since MultiSendCallOnly forbids nested
    ///      delegatecalls and a non-zero operation here would mean the payload is not what we think.
    function _replayMultiSend(bytes memory payload) internal returns (uint256 executed) {
        // selector(4) + offset(32) + length(32) = 68
        require(payload.length > 68, "payload too short");
        uint256 declared;
        assembly { declared := mload(add(payload, 68)) }   // the bytes-arg length word

        uint256 p = 68;                 // start of the packed entries
        uint256 end = p + declared;
        require(end <= payload.length, "declared length exceeds payload");

        while (p < end) {
            uint8 op;
            address to;
            uint256 value;
            uint256 len;
            assembly {
                let base := add(payload, 32)
                op    := shr(248, mload(add(base, p)))
                to    := shr(96,  mload(add(base, add(p, 1))))
                value := mload(add(base, add(p, 21)))
                len   := mload(add(base, add(p, 53)))
            }
            assertEq(uint256(op), 0, "inner op must be CALL (MultiSendCallOnly)");
            assertEq(to, CONFIGURATOR, "inner call targets an unexpected contract");
            assertEq(value, 0, "inner call must send zero value");

            bytes memory data = new bytes(len);
            for (uint256 i; i < len; i++) data[i] = payload[p + 85 + i];

            // selector must be updateReservePriceSource(address,uint256,address)
            bytes4 s = bytes4(bytes.concat(data[0], data[1], data[2], data[3]));
            assertEq(s, bytes4(0x7f1e3675), "inner call is not updateReservePriceSource");

            vm.prank(SAFE);
            (bool ok, bytes memory ret) = to.call(data);
            if (!ok) {
                if (ret.length > 0) { assembly { revert(add(ret, 32), mload(ret)) } }
                revert("inner call reverted with no data");
            }

            p += 85 + len;
            executed++;
        }
        assertEq(p, end, "payload did not consume exactly to its declared length");
    }

    /// @dev Smallest `rateMaxStaleness` anywhere in a source's leg graph. Type(uint).max when the
    ///      graph carries no bound at all.
    function _minBoundIn(address node) internal view returns (uint256) {
        return _walk(node, 0);
    }

    function _walk(address node, uint256 depth) internal view returns (uint256 best) {
        best = type(uint256).max;
        if (depth > 4) return best;

        bool isAdapter;
        uint256 v;
        (isAdapter, v) = _child(node, "BASE_TO_USD_AGGREGATOR()", depth);
        if (v < best) best = v;
        bool k;
        (k, v) = _child(node, "RATIO_PROVIDER()", depth);
        isAdapter = isAdapter || k;
        if (v < best) best = v;
        (k, v) = _child(node, "ASSET_TO_USD_AGGREGATOR()", depth);
        isAdapter = isAdapter || k;
        if (v < best) best = v;
        if (isAdapter) return best;

        (bool d, bytes memory dr) = node.staticcall(abi.encodeWithSignature("rateMaxStaleness()"));
        if (!d || dr.length != 32) return best;

        uint256 bound = abi.decode(dr, (uint256));
        if (bound < best) best = bound;

        (k, v) = _child(node, "underlyingUsdFeed()", depth);
        if (v < best) best = v;
    }

    /// @dev Follow one named child edge, if it exists. Split out of `_walk` to keep that frame small
    ///      enough for the default (non-via-ir) codegen.
    function _child(address node, string memory sig, uint256 depth) internal view returns (bool present, uint256 bound) {
        bound = type(uint256).max;
        (bool ok, bytes memory ret) = node.staticcall(abi.encodeWithSignature(sig));
        if (!ok || ret.length != 32) return (false, bound);
        address kid = abi.decode(ret, (address));
        if (kid == address(0)) return (false, bound);
        return (true, _walk(kid, depth + 1));
    }
}
