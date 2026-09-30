// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { TopUpDest } from "../../src/top-up/TopUpDest.sol";

/// @notice Upgrades the live OP TopUpDest to the wrapStock build on a fork and checks that the existing
///         deposit accounting survives and that a raw stock payout can be wrapped into wrapper deposit.
contract TopUpDestUpgradeForkTest is Test {
    address internal constant TOP_UP_DEST = 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87;
    address internal constant DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address internal constant OP_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant TOP_UP_WALLET = 0xf96f8E03615f7b71e0401238D28bb08CceECBae7;
    address internal constant BACKED_CUSTODY = 0x5F7A4c11bde4f218f0025Ef444c369d838ffa2aD;

    address internal constant IWSPYX = 0xc1e636Aae7d6B46229FC2C362d562610519e8D7c;
    address internal constant IWQQQX = 0x3c99d3a81b27583B2E26dbd387C10411f2763516;
    address internal constant IWTBLLX = 0x5F8b2D2b97aD4d63188f44965778F6004D5bc387;
    address internal constant SPYX = 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48;
    address internal constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;

    TopUpDest internal topUpDest = TopUpDest(payable(TOP_UP_DEST));

    function setUp() public {
        string memory rpc = vm.envOr("OPTIMISM_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
    }

    function test_upgrade_keepsDepositsAndWrapsRawStock() public {
        uint256 spyDeposit = topUpDest.getDeposit(IWSPYX);
        uint256 qqqDeposit = topUpDest.getDeposit(IWQQQX);
        uint256 tbllDeposit = topUpDest.getDeposit(IWTBLLX);
        bool pausedBefore = topUpDest.paused();
        assertGt(spyDeposit, 0, "live float expected");

        address newImpl = address(new TopUpDest(DATA_PROVIDER, OP_WETH));
        vm.prank(UPGRADE_TIMELOCK);
        topUpDest.upgradeToAndCall(newImpl, "");

        assertEq(topUpDest.getDeposit(IWSPYX), spyDeposit, "iwSPYx deposit drifted");
        assertEq(topUpDest.getDeposit(IWQQQX), qqqDeposit, "iwQQQx deposit drifted");
        assertEq(topUpDest.getDeposit(IWTBLLX), tbllDeposit, "iwTBLLx deposit drifted");
        assertEq(topUpDest.paused(), pausedBefore, "pause state drifted");
        assertEq(address(topUpDest.etherFiDataProvider()), DATA_PROVIDER);
        assertEq(topUpDest.stockWrapperFor(SPYX), address(0), "fresh mapping must be empty");

        address[] memory raws = new address[](1);
        address[] memory wrappers = new address[](1);
        raws[0] = SPYX;
        wrappers[0] = WSPYX;
        vm.prank(OPERATING_SAFE);
        topUpDest.setStockWrappers(raws, wrappers);

        // A bridge payout is a plain transfer from Backed's custody
        vm.prank(BACKED_CUSTODY);
        IERC20(SPYX).transfer(TOP_UP_DEST, 1e18);

        uint256 wrapperBefore = IERC20(WSPYX).balanceOf(TOP_UP_DEST);
        vm.prank(TOP_UP_WALLET);
        topUpDest.wrapStock(SPYX);

        uint256 shares = IERC20(WSPYX).balanceOf(TOP_UP_DEST) - wrapperBefore;
        assertGt(shares, 0, "no shares minted");
        assertLt(IERC20(SPYX).balanceOf(TOP_UP_DEST), 2, "raw stock left behind");
        assertEq(topUpDest.getDeposit(WSPYX), shares, "wrapper deposit not credited");
    }
}
