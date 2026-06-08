// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { AcrossFillVerifier } from "../../src/across/AcrossFillVerifier.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract AcrossFillVerifierTest is Test {
    AcrossFillVerifier internal verifier;
    MockToken internal token;
    MockToken internal otherToken;

    address internal user = makeAddr("user");
    address internal otherUser = makeAddr("otherUser");

    function setUp() public {
        verifier = new AcrossFillVerifier();
        token = new MockToken();
        otherToken = new MockToken();
    }

    // ---- Happy path ----

    function test_assertFilled_passesWhenDeltaEqualsMinOut() public {
        uint256 minOut = 100e18;
        verifier.register(user, address(token), minOut);
        token.mint(user, minOut);
        verifier.assertFilled(user, address(token));
    }

    function test_assertFilled_passesWhenDeltaExceedsMinOut() public {
        verifier.register(user, address(token), 100e18);
        token.mint(user, 250e18);
        verifier.assertFilled(user, address(token));
    }

    function test_assertFilled_passesWhenPreExistingBalanceAndDeltaMeetsMinOut() public {
        token.mint(user, 500e18);
        verifier.register(user, address(token), 100e18);
        token.mint(user, 100e18);
        verifier.assertFilled(user, address(token));
    }

    function test_minOutZero_passesWithZeroDelta() public {
        verifier.register(user, address(token), 0);
        verifier.assertFilled(user, address(token));
    }

    // ---- Reverts ----

    function test_assertFilled_revertsWithoutRegister() public {
        vm.expectRevert(AcrossFillVerifier.NotRegistered.selector);
        verifier.assertFilled(user, address(token));
    }

    function test_assertFilled_revertsWhenDeltaBelowMinOut() public {
        verifier.register(user, address(token), 100e18);
        token.mint(user, 99e18);
        vm.expectRevert(abi.encodeWithSelector(AcrossFillVerifier.InsufficientFill.selector, 100e18, 99e18));
        verifier.assertFilled(user, address(token));
    }

    function test_assertFilled_revertsWhenDeltaIsZero() public {
        verifier.register(user, address(token), 1);
        vm.expectRevert(abi.encodeWithSelector(AcrossFillVerifier.InsufficientFill.selector, 1, 0));
        verifier.assertFilled(user, address(token));
    }

    function test_assertFilled_revertsForDifferentTokenThanRegistered() public {
        verifier.register(user, address(token), 100e18);
        token.mint(user, 100e18);
        otherToken.mint(user, 100e18);
        // assertFilled for otherToken has no registration → reverts NotRegistered
        vm.expectRevert(AcrossFillVerifier.NotRegistered.selector);
        verifier.assertFilled(user, address(otherToken));
    }

    function test_assertFilled_revertsForDifferentUserThanRegistered() public {
        verifier.register(user, address(token), 100e18);
        token.mint(otherUser, 100e18);
        vm.expectRevert(AcrossFillVerifier.NotRegistered.selector);
        verifier.assertFilled(otherUser, address(token));
    }

    // ---- Overwrite within the same tx ----

    function test_register_overwritesPriorRegister_lastWriteWins() public {
        // First register: snapshot at 0, minOut 100
        verifier.register(user, address(token), 100e18);
        // User already received 100 (would satisfy the first register).
        token.mint(user, 100e18);
        // Re-register: snapshot now at 100, minOut 50
        verifier.register(user, address(token), 50e18);
        // Need another 50 on top — give 49 → should fail
        token.mint(user, 49e18);
        vm.expectRevert(abi.encodeWithSelector(AcrossFillVerifier.InsufficientFill.selector, 50e18, 49e18));
        verifier.assertFilled(user, address(token));
    }

    function test_register_overwritesPriorRegister_succeedsWithFreshDelta() public {
        verifier.register(user, address(token), 100e18);
        token.mint(user, 100e18);
        verifier.register(user, address(token), 50e18);
        token.mint(user, 50e18);
        verifier.assertFilled(user, address(token));
    }

    // ---- Isolation within a single tx ----

    function test_multipleTokens_sameUser_independent() public {
        verifier.register(user, address(token), 100e18);
        verifier.register(user, address(otherToken), 200e18);

        token.mint(user, 100e18);
        otherToken.mint(user, 200e18);

        verifier.assertFilled(user, address(token));
        verifier.assertFilled(user, address(otherToken));
    }

    function test_multipleUsers_sameToken_independent() public {
        verifier.register(user, address(token), 100e18);
        verifier.register(otherUser, address(token), 200e18);

        token.mint(user, 100e18);
        token.mint(otherUser, 200e18);

        verifier.assertFilled(user, address(token));
        verifier.assertFilled(otherUser, address(token));
    }

    function test_oneRegistrationFails_doesNotAffectOthers() public {
        verifier.register(user, address(token), 100e18);
        verifier.register(otherUser, address(token), 100e18);

        // only `user` gets enough
        token.mint(user, 100e18);
        token.mint(otherUser, 50e18);

        verifier.assertFilled(user, address(token));
        vm.expectRevert(abi.encodeWithSelector(AcrossFillVerifier.InsufficientFill.selector, 100e18, 50e18));
        verifier.assertFilled(otherUser, address(token));
    }

    // ---- Clear-on-success ----

    function test_assertFilled_clearsState_secondCallReverts() public {
        verifier.register(user, address(token), 100e18);
        token.mint(user, 100e18);
        verifier.assertFilled(user, address(token));
        // Second assertFilled in the same tx without a fresh register: must revert.
        vm.expectRevert(AcrossFillVerifier.NotRegistered.selector);
        verifier.assertFilled(user, address(token));
    }

    function test_assertFilled_clearsState_freshRegisterStillWorks() public {
        verifier.register(user, address(token), 100e18);
        token.mint(user, 100e18);
        verifier.assertFilled(user, address(token));
        // After clear, a brand-new register + assertFilled cycle works normally.
        verifier.register(user, address(token), 50e18);
        token.mint(user, 50e18);
        verifier.assertFilled(user, address(token));
    }

    // ---- Cross-tx isolation ----
    // Each test function is its own transaction in Foundry, so transient storage clears
    // between them. We assert it here by writing in one tx and observing fresh state
    // would revert in another (Foundry implicitly satisfies this — these are the same
    // assertion split across two tests).

    function test_transientCleared_step1_register() public {
        verifier.register(user, address(token), 100e18);
        // intentionally do nothing else; state should not survive
    }

    function test_transientCleared_step2_freshTxHasNoRegister() public {
        vm.expectRevert(AcrossFillVerifier.NotRegistered.selector);
        verifier.assertFilled(user, address(token));
    }

    // ---- Events ----

    function test_register_emitsRegistered() public {
        token.mint(user, 42e18);
        vm.expectEmit(true, true, true, true);
        emit AcrossFillVerifier.Registered(user, address(token), 100e18, 42e18);
        verifier.register(user, address(token), 100e18);
    }

    function test_assertFilled_emitsVerified() public {
        verifier.register(user, address(token), 100e18);
        token.mint(user, 137e18);
        vm.expectEmit(true, true, true, true);
        emit AcrossFillVerifier.Verified(user, address(token), 137e18);
        verifier.assertFilled(user, address(token));
    }

    // ---- Fuzz ----

    function testFuzz_passesIffDeltaMeetsMinOut(uint128 minOut, uint128 delta) public {
        verifier.register(user, address(token), minOut);
        token.mint(user, delta);
        if (delta >= minOut) {
            verifier.assertFilled(user, address(token));
        } else {
            vm.expectRevert(abi.encodeWithSelector(AcrossFillVerifier.InsufficientFill.selector, uint256(minOut), uint256(delta)));
            verifier.assertFilled(user, address(token));
        }
    }
}
