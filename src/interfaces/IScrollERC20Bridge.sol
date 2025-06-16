// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IL1MessageQueueV2 {
    function estimateCrossDomainMessageFee(uint256 _gasLimit) external view returns (uint256);
}

interface IL1GatewayRouter {
    function depositERC20(address _token, address _to, uint256 _amount, uint256 _gasLimit) external payable;
    function getERC20Gateway(address _token) external view returns (address);
}

interface IL1ERC20Gateway {
    function messenger() external view returns (address);
}

interface IL1ERC20Messenger {
    function messageQueueV2() external view returns (address);
}