// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.7.0;

/**
 * @notice Minimal vendored shim of LayerZero V1's `ILayerZeroUltraLightNodeV2`.
 *
 * LayerZero's test tooling (TestHelperOz5 -> DVNMock) imports this V1 interface, but the
 * lz-evm-v1-0.7 package is not vendored in this repo (we only carry the V2
 * stack). DVNMock uses exactly two members of it: withdrawNative(...) and
 * `updateHash.selector`. This shim declares those with the canonical V1 signatures so the
 * selector matches the real one (`updateHash(uint16,bytes32,uint256,bytes32)` == 0x704316e5),
 * letting the mock DVN's replay guard behave identically to upstream.
 *
 * Scope is deliberately limited to what `DVNMock` references — this is NOT a faithful copy of
 * the full V1 interface and should not be relied on beyond the test harness.
 */
interface ILayerZeroUltraLightNodeV2 {
    // An Oracle delivers the block data using updateHash(). Declared so its 4-byte selector
    // (0x704316e5) matches the canonical V1 signature used by DVNMock's replay guard.
    function updateHash(uint16 _srcChainId, bytes32 _lookupHash, uint256 _confirmations, bytes32 _blockData) external;

    // Workers withdraw their accrued native fees through the ULN.
    function withdrawNative(address _to, uint256 _amount) external;
}
