// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Fork-only stand-in for an ether.fi shadow OFT that is not deployed yet: a bare 18-decimal ERC20
///      (the listing rehearsal reads decimals(); nothing here moves tokens). No constructor state, so
///      its runtime code can be etched at the predicted address. Never deployed.
contract MockOft {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function symbol() external pure returns (string memory) {
        return "iMOCK";
    }
}
