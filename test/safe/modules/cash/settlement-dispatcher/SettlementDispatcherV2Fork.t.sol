// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { SettlementDispatcherV2 } from "../../../../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { IRoleRegistry } from "../../../../../src/interfaces/IRoleRegistry.sol";
import { IFraxCustodian } from "../../../../../src/interfaces/IFraxCustodian.sol";
import { IFraxRemoteHop } from "../../../../../src/interfaces/IFraxRemoteHop.sol";
import { IMidasVault } from "../../../../../src/interfaces/IMidasVault.sol";
import { MessagingFee } from "../../../../../src/interfaces/IOFT.sol";
import { BinSponsor } from "../../../../../src/interfaces/ICashModule.sol";

/**
 * @notice Fork tests for SettlementDispatcherV2 on Scroll mainnet.
 *         Tests the Frax (sync + async) and Midas Liquid Reserve redemption flows
 *         by upgrading the deployed Rain settlement dispatcher proxy.
 */
contract SettlementDispatcherV2ForkTest is Test {

    // ── Deployed addresses on Scroll (chain 534352) ──────────────────────
    address constant SETTLEMENT_DISPATCHER_RAIN = 0x50A233C4a0Bb1d7124b0224880037d35767a501C;
    address constant ROLE_REGISTRY             = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address constant DATA_PROVIDER             = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;

    // Tokens
    address constant USDC       = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;
    address constant FRAX_USD   = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
    address constant MIDAS_LR   = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0; // Liquid Reserve

    // Frax infrastructure
    address constant FRAX_CUSTODIAN  = 0x05bF905356fbeA7E59500f904b908402dB7A53DD;
    address constant FRAX_REMOTE_HOP = 0xF6f45CCB5E85D1400067ee66F9e168f83e86124E;

    // Midas infrastructure
    address constant MIDAS_REDEMPTION_VAULT = 0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25;

    // Frax async recipient (from Frax API – used in their module tests)
    address constant FRAX_DEPOSIT_ADDRESS = 0xBdeb781661142740328fDefc1D9ecd03778fd810;

    SettlementDispatcherV2 v2;
    address owner; // RoleRegistry owner (multisig)

    function setUp() public {
        // Fork Scroll mainnet
        string memory scrollRpc = vm.envOr("SCROLL_RPC", string("https://rpc.scroll.io"));
        vm.createSelectFork(scrollRpc);

        // Resolve the RoleRegistry owner so we can impersonate it
        owner = IRoleRegistry(ROLE_REGISTRY).owner();

        // Deploy new V2 implementation and upgrade the Rain dispatcher proxy
        SettlementDispatcherV2 impl = new SettlementDispatcherV2(BinSponsor.Rain, DATA_PROVIDER);

        vm.startPrank(owner);
        UUPSUpgradeable(SETTLEMENT_DISPATCHER_RAIN).upgradeToAndCall(address(impl), "");
        vm.stopPrank();

        v2 = SettlementDispatcherV2(payable(SETTLEMENT_DISPATCHER_RAIN));

        // Grant the bridger role to the owner so we can call bridger-gated functions
        vm.startPrank(owner);
        IRoleRegistry(ROLE_REGISTRY).grantRole(v2.SETTLEMENT_DISPATCHER_BRIDGER_ROLE(), owner);
        vm.stopPrank();
    }

    // =====================================================================
    //  Frax sync redeem (redeemFraxToUsdc)
    // =====================================================================

    function test_fork_redeemFraxToUsdc() public {
        uint256 amount = 100e18;

        // Configure Frax on the dispatcher
        vm.prank(owner);
        v2.setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS);

        // Fund the dispatcher with Frax USD and ensure custodian has USDC
        deal(FRAX_USD, address(v2), amount);
        deal(USDC, FRAX_CUSTODIAN, 200e6);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(v2));
        uint256 fraxBefore = IERC20(FRAX_USD).balanceOf(address(v2));

        vm.prank(owner);
        v2.redeemFraxToUsdc(amount, 0); // minReceive = 0 since custodian return is variable on fork

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(v2));
        uint256 fraxAfter = IERC20(FRAX_USD).balanceOf(address(v2));

        assertLt(fraxAfter, fraxBefore, "Frax USD should decrease");
        assertGt(usdcAfter, usdcBefore, "USDC should increase");
    }

    // =====================================================================
    //  Frax async redeem (redeemFraxAsync via RemoteHop / LayerZero OFT)
    // =====================================================================

    function test_fork_redeemFraxAsync() public {
        uint256 amount = 100e18; // must be multiple of DUST_THRESHOLD (1e12)

        // Configure Frax
        vm.prank(owner);
        v2.setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS);

        // Fund the dispatcher with Frax USD
        deal(FRAX_USD, address(v2), amount);

        // Quote the LZ fee
        MessagingFee memory fee = v2.quoteAsyncFraxRedeem(amount);

        // Fund dispatcher with ETH for the fee
        vm.deal(address(v2), fee.nativeFee + 0.1 ether);

        uint256 fraxBefore = IERC20(FRAX_USD).balanceOf(address(v2));

        vm.prank(owner);
        v2.redeemFraxAsync{ value: fee.nativeFee }(amount);

        uint256 fraxAfter = IERC20(FRAX_USD).balanceOf(address(v2));

        assertEq(fraxAfter, fraxBefore - amount, "Frax USD should be sent cross-chain");
    }

    function test_fork_quoteAsyncFraxRedeem() public {
        // Configure Frax
        vm.prank(owner);
        v2.setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS);

        MessagingFee memory fee = v2.quoteAsyncFraxRedeem(100e18);
        assertGt(fee.nativeFee, 0, "Native fee should be > 0");
    }

    // =====================================================================
    //  Midas Liquid Reserve redeem (redeemMidasToAsset)
    // =====================================================================

    function test_fork_redeemMidasToAsset() public {
        uint256 amount = 100e18; // Midas token is 18 decimals

        // Configure Midas redemption vault
        vm.prank(owner);
        v2.setMidasRedemptionVault(MIDAS_LR, MIDAS_REDEMPTION_VAULT);

        // Fund the dispatcher with Midas Liquid Reserve tokens
        deal(MIDAS_LR, address(v2), amount);

        uint256 midasBefore = IERC20(MIDAS_LR).balanceOf(address(v2));

        vm.prank(owner);
        v2.redeemMidasToAsset(MIDAS_LR, USDC, amount, 0);

        uint256 midasAfter = IERC20(MIDAS_LR).balanceOf(address(v2));

        assertLt(midasAfter, midasBefore, "Midas LR balance should decrease after redeem request");
    }

    // =====================================================================
    //  Config setter tests
    // =====================================================================

    function test_fork_setFraxConfig() public {
        vm.prank(owner);
        v2.setFraxConfig(FRAX_USD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP, FRAX_DEPOSIT_ADDRESS);

        (address fraxUsd_, address fraxCustodian_, address fraxRemoteHop_, address fraxAsyncRedeemRecipient_) = v2.getFraxConfig();
        assertEq(fraxUsd_, FRAX_USD);
        assertEq(fraxCustodian_, FRAX_CUSTODIAN);
        assertEq(fraxRemoteHop_, FRAX_REMOTE_HOP);
        assertEq(fraxAsyncRedeemRecipient_, FRAX_DEPOSIT_ADDRESS);
    }

    function test_fork_setMidasRedemptionVault() public {
        vm.prank(owner);
        v2.setMidasRedemptionVault(MIDAS_LR, MIDAS_REDEMPTION_VAULT);

        assertEq(v2.getMidasRedemptionVault(MIDAS_LR), MIDAS_REDEMPTION_VAULT);
    }
}
