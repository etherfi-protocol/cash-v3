// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ILayerZeroTeller {
    struct Asset {
        bool allowDeposits;
        bool allowWithdraws;
        uint16 sharePremium;
    }   

    function vault() external view returns (BoringVault);
    function assetData(ERC20 asset) external view returns (Asset memory);
    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint) external payable returns (uint256 shares);
    function bridge(uint96 shareAmount, address to, bytes calldata bridgeWildCard, ERC20 feeToken, uint256 maxFee) external payable;
    function previewFee(uint96 shareAmount, address to, bytes calldata bridgeWildCard, ERC20 feeToken) external view returns (uint256 fee);
    function accountant() external view returns (AccountantWithRateProviders);
}

interface BoringVault {}

interface AccountantWithRateProviders {
    function getRate() external view returns (uint256 rate);
    function decimals() external view returns (uint8);
}