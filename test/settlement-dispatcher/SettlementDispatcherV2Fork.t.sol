// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SettlementDispatcherV2} from "../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import {BinSponsor} from "../../src/interfaces/ICashModule.sol";

/**
 * @title SettlementDispatcherV2ForkTest
 * @notice Fork tests against Scroll mainnet for Frax and Midas redeem flows.
 *         Upgrades the Rain dispatcher to the latest SettlementDispatcherV2 implementation,
 *         configures Frax / Midas, and exercises the on-chain redeem paths.
 */
contract SettlementDispatcherV2ForkTest is Test {
    // --- Scroll mainnet addresses ---
    address constant SETTLEMENT_DISPATCHER_RAIN = 0x50A233C4a0Bb1d7124b0224880037d35767a501C;
    address constant ROLE_REGISTRY = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address constant DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant BRIDGER = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    address constant FRAX_USD = 0x397F939C3b91A74C321ea7129396492bA9Cdce82;
    address constant FRAX_CUSTODIAN = 0x05bF905356fbeA7E59500f904b908402dB7A53DD;

    address constant MIDAS_TOKEN = 0xb7Fb3768CAAC98354EaDF514b48f28F2fE822bF0;
    address constant MIDAS_REDEMPTION_VAULT = 0x904EA8d7FcaB7351758fAC82bDbc738E2010BC25;

    address constant USDC = 0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4;

    // --- State ---
    SettlementDispatcherV2 v2;
    address owner;

    function setUp() public {
        string memory rpc = vm.envOr("SCROLL_RPC", string("https://rpc.scroll.io"));
        vm.createSelectFork(rpc);

        // Resolve the on-chain RoleRegistry owner (Solady Ownable)
        owner = Ownable(ROLE_REGISTRY).owner();

        // Deploy a new V2 implementation with Rain bin sponsor and upgrade the proxy
        address newImpl = address(new SettlementDispatcherV2(BinSponsor.Rain, DATA_PROVIDER));
        vm.prank(owner);
        UUPSUpgradeable(SETTLEMENT_DISPATCHER_RAIN).upgradeToAndCall(newImpl, "");

        v2 = SettlementDispatcherV2(payable(SETTLEMENT_DISPATCHER_RAIN));

        // Configure Frax and Midas on the upgraded dispatcher
        vm.startPrank(owner);
        v2.setFraxConfig(FRAX_USD, FRAX_CUSTODIAN);
        v2.setMidasRedemptionVault(MIDAS_TOKEN, MIDAS_REDEMPTION_VAULT);
        vm.stopPrank();
    }

    // -------------------------------------------------------
    // Test 1 – redeemFraxToUsdc (synchronous on-chain redeem)
    // -------------------------------------------------------
    function test_redeemFraxToUsdc() public {
        uint256 amount = 1e18; // 1 Frax USD (18 decimals)

        // Fund the dispatcher with Frax USD
        deal(FRAX_USD, address(v2), amount);

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(v2));
        uint256 fraxBefore = IERC20(FRAX_USD).balanceOf(address(v2));

        // Call as bridger with minReceive = 0 to avoid slippage revert
        vm.prank(BRIDGER);
        v2.redeemFraxToUsdc(amount, 0);

        // Frax balance should have decreased by amount
        assertEq(IERC20(FRAX_USD).balanceOf(address(v2)), fraxBefore - amount, "Frax balance did not decrease");

        // USDC balance should have increased
        assertGt(IERC20(USDC).balanceOf(address(v2)), usdcBefore, "USDC balance did not increase");
    }

    // -------------------------------------------------------
    // Test 2 – redeemMidasToAsset (async redemption request)
    // -------------------------------------------------------
    function test_redeemMidasToAsset() public {
        uint256 amount = 1e18; // 1 Midas token (18 decimals for Liquid Reserve)

        // Fund the dispatcher with Midas tokens
        deal(MIDAS_TOKEN, address(v2), amount);

        uint256 midasBefore = IERC20(MIDAS_TOKEN).balanceOf(address(v2));

        // Expect the MidasRedeemed event
        vm.expectEmit(true, true, true, true);
        emit SettlementDispatcherV2.MidasRedeemed(MIDAS_TOKEN, USDC, amount, 0);

        // Call as bridger
        vm.prank(BRIDGER);
        v2.redeemMidasToAsset(MIDAS_TOKEN, USDC, amount, 0);

        // Midas balance should have decreased (tokens transferred to vault)
        assertEq(
            IERC20(MIDAS_TOKEN).balanceOf(address(v2)),
            midasBefore - amount,
            "Midas token balance did not decrease"
        );

        // NOTE: Do NOT assert USDC increase — redeemRequest is async; the vault
        // sends USDC to the dispatcher later when the request is processed.
    }
}
