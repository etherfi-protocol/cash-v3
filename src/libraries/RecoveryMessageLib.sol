// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title RecoveryMessageLib
 * @author ether.fi
 * @notice Encode/decode for the cross-chain recovery payload.
 * @dev No amount field: the destination sweeps the full balance at receipt.
 */
library RecoveryMessageLib {
    struct Payload {
        address safe;
        address token;
        address recipient;
    }

    function encode(Payload memory p) internal pure returns (bytes memory) {
        return abi.encode(p.safe, p.token, p.recipient);
    }

    function decode(bytes calldata data) internal pure returns (Payload memory p) {
        (p.safe, p.token, p.recipient) = abi.decode(data, (address, address, address));
    }
}
