// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title RecoveryMessageLib
 * @author ether.fi
 * @notice Encoding helpers for the cross-chain recovery payload
 */
library RecoveryMessageLib {
    struct Payload {
        address safe;
        address token;
        uint256 amount;
        address recipient;
    }

    function encode(Payload memory p) internal pure returns (bytes memory) {
        return abi.encode(p.safe, p.token, p.amount, p.recipient);
    }

    function decode(bytes calldata data) internal pure returns (Payload memory p) {
        (p.safe, p.token, p.amount, p.recipient) = abi.decode(data, (address, address, uint256, address));
    }
}
