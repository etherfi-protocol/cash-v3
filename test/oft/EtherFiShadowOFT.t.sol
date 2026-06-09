// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOFT } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import { EtherFiShadowOFT } from "../../src/oft/EtherFiShadowOFT.sol";
import { OFTTestSetup } from "./OFTTestSetup.t.sol";

contract EtherFiShadowOFTTest is OFTTestSetup {
    uint8 internal constant SHARED_DECIMALS = 6;

    /* helper: deploy an initialized iTOKEN proxy off the shadow factory's beacon. We build the
       proxy directly (not via the factory) so an initialize revert surfaces the real error,
       not the factory's wrapped InitializationFailed. */
    function _deployShadow(string memory name, string memory symbol, uint8 dec, address del) internal returns (EtherFiShadowOFT) {
        bytes memory initData = abi.encodeWithSelector(EtherFiShadowOFT.initialize.selector, name, symbol, dec, del);
        return EtherFiShadowOFT(address(new BeaconProxy(shadowFactory.beacon(), initData)));
    }

    // helper: an UNinitialized proxy (empty initData) so we can call initialize() directly in tests.
    function _uninitializedShadow() internal returns (EtherFiShadowOFT) {
        return EtherFiShadowOFT(address(new BeaconProxy(shadowFactory.beacon(), "")));
    }

    // decimals() must mirror the underlying token's decimals (iUSDC=6, iWBTC=8, iPAXG=18).
    function test_decimals_mirrorUnderlying() public {
        assertEq(_deployShadow("EtherFi USDC", "iUSDC", 6, delegate).decimals(), 6);
        assertEq(_deployShadow("EtherFi WBTC", "iWBTC", 8, delegate).decimals(), 8);
        assertEq(_deployShadow("EtherFi PAXG", "iPAXG", 18, delegate).decimals(), 18);
    }

    // The per-proxy conversion rate is 10**(localDecimals - 6): 6->1, 8->100, 18->1e12.
    function test_conversionRate_perDecimals() public {
        assertEq(_deployShadow("a", "a", 6, delegate).conversionRate(), 1);
        assertEq(_deployShadow("b", "b", 8, delegate).conversionRate(), 100);
        assertEq(_deployShadow("c", "c", 18, delegate).conversionRate(), 1e12);
    }

    // Each iTOKEN proxy is its own ERC-20 with the name/symbol passed at init.
    function test_nameAndSymbolSet() public {
        EtherFiShadowOFT s = _deployShadow("EtherFi USDC", "iUSDC", 6, delegate);
        assertEq(s.name(), "EtherFi USDC");
        assertEq(s.symbol(), "iUSDC");
    }

    // Before init, decimals() returns the placeholder (18) instead of 0.
    function test_decimals_returnsPlaceholderBeforeInit() public {
        // Uninitialized proxy: storage localDecimals == 0 -> placeholder (18). This is exactly
        // what lets the parent constructor's `decimals() >= sharedDecimals` check pass at IMPL
        // deploy (when storage is still zero); returning 0 there would revert the impl deploy.
        assertEq(_uninitializedShadow().decimals(), 18);
    }

    // initialize rejects sub-6 decimals (LZ wire format is 6-dec; sub-6 is out of scope).
    function test_initialize_reverts_belowSharedDecimals() public {
        EtherFiShadowOFT s = _uninitializedShadow();
        vm.expectRevert(IOFT.InvalidLocalDecimals.selector);
        s.initialize("x", "x", SHARED_DECIMALS - 1, delegate);
    }

    // initialize rejects a zero delegate (checked before the decimals check).
    function test_initialize_reverts_onZeroDelegate() public {
        EtherFiShadowOFT s = _uninitializedShadow();
        vm.expectRevert(EtherFiShadowOFT.InvalidAddress.selector);
        s.initialize("x", "x", 6, address(0));
    }

    // initialize can only run once per proxy (OZ initializer guard).
    function test_initialize_cannotReinitialize() public {
        EtherFiShadowOFT s = _deployShadow("a", "a", 6, delegate);
        vm.expectRevert(); // InvalidInitialization (OZ) — already initialized
        s.initialize("a", "a", 6, delegate);
    }
}
