// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";

/// @title Create3Deployer
/// @notice One-shot helper that performs a CREATE3 deployment through Nick's factory inside a
///         single constructor, then self-verifies. Deploy-and-forget: the helper's own address
///         is irrelevant — the CREATE3 address depends only on (factory, salt).
/// @dev Exists because the raw two-tx flow (factory call, then proxy call) is fragile under
///      broadcast: the CREATE3 proxy returns success even when its inner CREATE fails (e.g.
///      out of gas), so eth_estimateGas can converge on a gas limit where the outer tx
///      "succeeds" but nothing is deployed — observed on Arbitrum. Wrapping the whole flow in
///      a constructor that reverts on failure forces estimation to find a gas limit where the
///      deployment actually lands, and makes the operation atomic (no tx-ordering race).
contract Create3Deployer {
    address constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    constructor(bytes memory creationCode, bytes32 salt) {
        address deployed = CREATE3.predictDeterministicAddress(salt, NICKS_FACTORY);

        if (deployed.code.length == 0) {
            address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", NICKS_FACTORY, salt, CREATE3.PROXY_INITCODE_HASH)))));

            bool ok;
            if (proxy.code.length == 0) {
                (ok,) = NICKS_FACTORY.call(abi.encodePacked(salt, hex"67363d3d37363d34f03d5260086018f3"));
                require(ok, "CREATE3 proxy deploy failed");
            }

            (ok,) = proxy.call(creationCode);
            require(ok, "CREATE3 contract deploy failed");
        }

        require(deployed.code.length > 0, "CREATE3 deployment verification failed");
    }
}
