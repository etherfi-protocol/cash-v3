// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOFT } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { MockERC20, OFTTestSetup } from "./OFTTestSetup.t.sol";

/**
 * Exposes the internal decimal-scaling math (_removeDust / _toSD / _toLD) so the SD<->LD
 * truncation rules can be fuzzed directly, without driving a cross-chain send. The adapter and
 * shadow share identical overrides (both read the per-proxy rate from storage), so testing one
 * covers the math for both; the cross-chain fuzz in OFTRoundTrip proves they agree end to end.
 */
contract DecimalMathHarness is EtherFiOFTAdapter {
    constructor(address ep, address reg) EtherFiOFTAdapter(ep, reg) { }

    function removeDust(uint256 a) external view returns (uint256) {
        return _removeDust(a);
    }

    function toSD(uint256 a) external view returns (uint64) {
        return _toSD(a);
    }

    function toLD(uint64 a) external view returns (uint256) {
        return _toLD(a);
    }
}

/**
 * @title OFTDecimalsFuzzTest
 * @notice Fuzz the decimal/dust math across the supported 6..18-decimal range:
 *         dust truncation never rounds up, sub-rate amounts collapse to zero, the SD round-trip
 *         is lossless on clean amounts, and the uint64 SD ceiling reverts rather than silently
 *         overflowing.
 */
contract OFTDecimalsFuzzTest is OFTTestSetup {
    uint8 internal constant SHARED_DECIMALS = 6;

    // Deploy a math harness whose per-proxy rate is 10**(decimals-6).
    function _harness(uint8 decimals) internal returns (DecimalMathHarness h) {
        MockERC20 t = new MockERC20("T", "T", decimals);
        address impl = address(new DecimalMathHarness(address(endpoint), address(configRegistry)));
        UpgradeableBeacon beacon = new UpgradeableBeacon(impl, owner);
        bytes memory initData = abi.encodeWithSelector(EtherFiOFTAdapter.initialize.selector, address(t), delegate);
        h = DecimalMathHarness(address(new BeaconProxy(address(beacon), initData)));
    }

    // The conversion rate is exactly 10**(decimals - 6) for every supported precision.
    function testFuzz_conversionRate_perDecimals(uint8 decimals) public {
        decimals = uint8(bound(decimals, SHARED_DECIMALS, 18));
        DecimalMathHarness h = _harness(decimals);
        assertEq(h.conversionRate(), 10 ** (decimals - SHARED_DECIMALS));
    }

    // _removeDust floors to a multiple of the rate: result <= input, result is a clean multiple,
    // and it discards strictly less than one rate unit. Truncation, never rounding up.
    function testFuzz_removeDust_truncatesDown(uint8 decimals, uint256 amount) public {
        decimals = uint8(bound(decimals, SHARED_DECIMALS, 18));
        uint256 rate = 10 ** (decimals - SHARED_DECIMALS);
        // keep amount under the SD ceiling so _removeDust itself can't be poisoned by overflow elsewhere
        amount = bound(amount, 0, uint256(type(uint64).max) * rate);
        DecimalMathHarness h = _harness(decimals);

        uint256 clean = h.removeDust(amount);
        assertLe(clean, amount, "dust removal increased the amount");
        assertEq(clean % rate, 0, "result is not a multiple of the rate");
        assertEq(amount - clean, amount % rate, "discarded more/less than the true dust");
        assertLt(amount - clean, rate, "discarded a whole rate unit");
    }

    // Sub-rate amounts (strictly less than one SD unit) collapse to zero in both directions.
    function testFuzz_subRateAmount_collapsesToZero(uint8 decimals, uint256 amount) public {
        decimals = uint8(bound(decimals, SHARED_DECIMALS + 1, 18)); // rate > 1 so a sub-rate band exists
        uint256 rate = 10 ** (decimals - SHARED_DECIMALS);
        amount = bound(amount, 0, rate - 1);
        DecimalMathHarness h = _harness(decimals);

        assertEq(h.removeDust(amount), 0);
        assertEq(h.toSD(amount), 0);
    }

    // The SD<->LD round-trip is lossless once dust is removed: toLD(toSD(x)) == removeDust(x).
    function testFuzz_sdRoundTrip_isLosslessAfterDustRemoval(uint8 decimals, uint256 amount) public {
        decimals = uint8(bound(decimals, SHARED_DECIMALS, 18));
        uint256 rate = 10 ** (decimals - SHARED_DECIMALS);
        amount = bound(amount, 0, uint256(type(uint64).max) * rate);
        DecimalMathHarness h = _harness(decimals);

        uint256 clean = h.removeDust(amount);
        assertEq(h.toLD(h.toSD(amount)), clean, "SD round-trip lost or created value");
    }

    // Zero is a fixed point of all three transforms.
    function test_zero_isFixedPoint() public {
        DecimalMathHarness h = _harness(18);
        assertEq(h.removeDust(0), 0);
        assertEq(h.toSD(0), 0);
        assertEq(h.toLD(0), 0);
    }

    // Just above the uint64 SD ceiling, _toSD reverts AmountSDOverflowed instead of wrapping.
    function test_toSD_revertsAboveUint64Ceiling() public {
        DecimalMathHarness h = _harness(18); // rate = 1e12
        uint256 rate = 1e12;
        // one SD unit past the max representable shared-decimal amount
        uint256 overflowLD = (uint256(type(uint64).max) + 1) * rate;
        vm.expectRevert(abi.encodeWithSelector(IOFT.AmountSDOverflowed.selector, uint256(type(uint64).max) + 1));
        h.toSD(overflowLD);
    }

    // The largest representable amount (exactly uint64.max SD units) does NOT revert.
    function test_toSD_maxRepresentable_ok() public {
        DecimalMathHarness h = _harness(18);
        uint256 rate = 1e12;
        uint256 maxLD = uint256(type(uint64).max) * rate;
        assertEq(h.toSD(maxLD), type(uint64).max);
        assertEq(h.toLD(type(uint64).max), maxLD);
    }
}
