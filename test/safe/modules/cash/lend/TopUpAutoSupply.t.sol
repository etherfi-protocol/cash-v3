// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { CashVerificationLib } from "../../../../../src/libraries/CashVerificationLib.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { TopUpDest } from "../../../../../src/top-up/TopUpDest.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title TopUpAutoSupplyTest
 * @notice Fork tests for topup auto-supply: TopUpDest, as a gateway driver, supplies a topped-up amount into
 *         Aave for the safe in the same tx, falling back to a plain loose topup on any failure.
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path test/safe/modules/cash/lend/TopUpAutoSupply.t.sol
 */
contract TopUpAutoSupplyTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    TopUpDest internal topUpDest;
    address internal topUpKeeper = makeAddr("topUpKeeper");

    bytes32 internal constant SRC_TX_HASH = keccak256("srcTx");
    uint256 internal constant SRC_CHAIN_ID = 1;
    uint256 internal constant TOP_UP_USDC = 1000e6;

    function setUp() public override {
        super.setUp();

        address impl = address(new TopUpDest(address(dataProvider), makeAddr("weth")));
        topUpDest = TopUpDest(payable(address(new UUPSProxy(impl, abi.encodeWithSelector(TopUpDest.initialize.selector, address(roleRegistry))))));

        vm.startPrank(owner);
        roleRegistry.grantRole(topUpDest.TOP_UP_ROLE(), topUpKeeper);
        gw.setDriver(address(topUpDest), true);
        vm.stopPrank();
    }

    /// A topup to an Aave safe lands supplied and flagged as collateral, nothing stays loose, and the TopUp
    /// event carries the raw token so the indexer never sees a different asset.
    function test_topUp_suppliesForAaveSafe() public {
        deal(address(usdc), address(topUpDest), TOP_UP_USDC);

        vm.expectEmit(true, true, true, true);
        emit TopUpDest.TopUp(topUpDest.getTxId(SRC_TX_HASH, address(safe), address(usdc)), address(safe), address(usdc), SRC_TX_HASH, SRC_CHAIN_ID, TOP_UP_USDC);
        vm.prank(topUpKeeper);
        topUpDest.topUpUserSafe(SRC_TX_HASH, address(safe), SRC_CHAIN_ID, address(usdc), TOP_UP_USDC);

        assertEq(gw.suppliedOf(address(safe), address(usdc)), TOP_UP_USDC, "topup landed supplied");
        assertEq(usdc.balanceOf(address(safe)), 0, "nothing left loose");
        assertGt(gw.getAccountData(address(safe)).availableBorrowsUsd, 0, "supplied topup counts as collateral");
    }

    /// The supply covers only the topped-up amount: a pre-existing loose balance stays loose.
    function test_topUp_leavesPriorLooseBalanceUntouched() public {
        uint256 priorLoose = 250e6;
        deal(address(usdc), address(safe), priorLoose);
        deal(address(usdc), address(topUpDest), TOP_UP_USDC);

        vm.prank(topUpKeeper);
        topUpDest.topUpUserSafe(SRC_TX_HASH, address(safe), SRC_CHAIN_ID, address(usdc), TOP_UP_USDC);

        assertEq(gw.suppliedOf(address(safe), address(usdc)), TOP_UP_USDC, "only the topup amount supplied");
        assertEq(usdc.balanceOf(address(safe)), priorLoose, "prior loose balance untouched");
    }

    /// An opted-out safe keeps its topup loose.
    function test_topUp_leavesLooseWhenOptedOut() public {
        _optOut();
        deal(address(usdc), address(topUpDest), TOP_UP_USDC);

        vm.prank(topUpKeeper);
        topUpDest.topUpUserSafe(SRC_TX_HASH, address(safe), SRC_CHAIN_ID, address(usdc), TOP_UP_USDC);

        assertEq(usdc.balanceOf(address(safe)), TOP_UP_USDC, "topup stayed loose");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0, "nothing supplied");
    }

    /// A legacy safe keeps its topup loose.
    function test_topUp_leavesLooseForLegacySafe() public {
        _forceLegacyEngine(address(safe));
        deal(address(usdc), address(topUpDest), TOP_UP_USDC);

        vm.prank(topUpKeeper);
        topUpDest.topUpUserSafe(SRC_TX_HASH, address(safe), SRC_CHAIN_ID, address(usdc), TOP_UP_USDC);

        assertEq(usdc.balanceOf(address(safe)), TOP_UP_USDC, "topup stayed loose");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), 0, "nothing supplied");
    }

    /// A token with no Aave reserve keeps its topup loose.
    function test_topUp_leavesLooseForUnregisteredToken() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        uint256 amount = 5 ether;
        stray.mint(address(topUpDest), amount);

        vm.prank(topUpKeeper);
        topUpDest.topUpUserSafe(SRC_TX_HASH, address(safe), SRC_CHAIN_ID, address(stray), amount);

        assertEq(stray.balanceOf(address(safe)), amount, "topup stayed loose");
    }

    /// A failing supply (gateway paused here) never blocks the topup; funds stay loose for the sweep.
    function test_topUp_succeedsWhenSupplyFails() public {
        vm.prank(pauser);
        gw.pause();
        deal(address(usdc), address(topUpDest), TOP_UP_USDC);

        bytes memory reason = abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector);
        vm.expectEmit(true, true, false, true, address(topUpDest));
        emit TopUpDest.LendSupplyFailed(address(safe), address(usdc), TOP_UP_USDC, reason);
        vm.prank(topUpKeeper);
        topUpDest.topUpUserSafe(SRC_TX_HASH, address(safe), SRC_CHAIN_ID, address(usdc), TOP_UP_USDC);

        assertEq(usdc.balanceOf(address(safe)), TOP_UP_USDC, "topup stayed loose");
        assertTrue(topUpDest.isTransactionCompleted(SRC_TX_HASH, address(safe), address(usdc)), "topup marked processed");
    }

    /// Same when TopUpDest is not (or no longer) an authorized driver.
    function test_topUp_succeedsWhenNotADriver() public {
        vm.prank(owner);
        gw.setDriver(address(topUpDest), false);
        deal(address(usdc), address(topUpDest), TOP_UP_USDC);

        vm.prank(topUpKeeper);
        topUpDest.topUpUserSafe(SRC_TX_HASH, address(safe), SRC_CHAIN_ID, address(usdc), TOP_UP_USDC);

        assertEq(usdc.balanceOf(address(safe)), TOP_UP_USDC, "topup stayed loose");
    }

    /// The supply hook is self-call only.
    function test_supplyTopUpToLend_revertsWhenNotSelf() public {
        vm.expectRevert(TopUpDest.OnlySelf.selector);
        topUpDest.supplyTopUpToLend(address(safe), address(usdc), 1);
    }

    /// @dev Opts the safe out of the lend market, riding out the mode-change delay.
    function _optOut() internal {
        uint256 nonce = cashModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(CashVerificationLib.TOGGLE_LEND_METHOD, block.chainid, address(safe), nonce, abi.encode(false))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        cashModule.toggleLend(address(safe), false, owner1, abi.encodePacked(r, s, v));
        (,, uint64 modeDelay) = cashModule.getDelays();
        if (modeDelay != 0) {
            vm.warp(block.timestamp + modeDelay + 1);
            cashModule.processLendOptOut(address(safe));
        }
    }
}
