// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

interface IFraxRemoteHop {
    function sendOFT(address _oft, uint32 _dstEid, bytes32 _to, uint256 _amountLD) external payable; 
    function quote(address _oft, uint32 _dstEid, bytes32 _to, uint256 _amountLD) external view returns (MessagingFee memory fee);
}