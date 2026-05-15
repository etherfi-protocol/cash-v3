// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title RecoveryMessageLib
 * @author ether.fi
 * @notice Encode/decode for the cross-chain recovery payload.
 * @dev No amount field: the destination sweeps the full balance at receipt. `salt` is the
 *      CREATE3 salt that produced both the OP-side Safe and the dest-chain TopUp; it travels
 *      so the dispatcher can lazily deploy TopUp if it isn't there yet (e.g. only an
 *      unsupported token ever reached this chain, so the topup batch path never ran).
 */
library RecoveryMessageLib {
    struct Payload {
        address safe;
        address token;
        address recipient;
        bytes32 salt;
    }

    function encode(Payload memory p) internal pure returns (bytes memory) {
        return abi.encode(p.safe, p.token, p.recipient, p.salt);
    }

    function decode(bytes calldata data) internal pure returns (Payload memory p) {
        (p.safe, p.token, p.recipient, p.salt) = abi.decode(data, (address, address, address, bytes32));
    }
}
