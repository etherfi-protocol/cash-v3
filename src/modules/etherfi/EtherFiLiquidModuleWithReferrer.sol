// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { ILayerZeroTeller } from "../../interfaces/ILayerZeroTeller.sol";
import { EtherFiLiquidModule } from "./EtherFiLiquidModule.sol";

interface ILayerZeroTellerWithReferrer is ILayerZeroTeller {
    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint, address referrerAddress) external payable returns (uint256 shares);
}

/**
 * @title EtherFiLiquidModuleWithReferrer
 * @author ether.fi
 * @notice EtherFiLiquidModule variant for vaults whose teller takes a referrer argument on deposit
 * @dev Only the teller deposit encoding differs from the base: the referrer-flavored selector with a zero
 *      referrer. Everything else, including the Aave gateway sandwich, is inherited.
 */
contract EtherFiLiquidModuleWithReferrer is EtherFiLiquidModule {
    constructor(address[] memory _assets, address[] memory _tellers, address _etherFiDataProvider, address _weth) EtherFiLiquidModule(_assets, _tellers, _etherFiDataProvider, _weth) { }

    /// @dev The referrer-flavored teller deposit, attributing no referrer.
    function _encodeTellerDeposit(address depositAsset, uint256 amountToDeposit, uint256 minReturn) internal pure override returns (bytes memory) {
        return abi.encodeWithSelector(ILayerZeroTellerWithReferrer.deposit.selector, ERC20(depositAsset), amountToDeposit, minReturn, address(0));
    }
}
