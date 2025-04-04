// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { ILayerZeroTeller } from "../../interfaces/ILayerZeroTeller.sol";
import { BridgeAdapterBase } from "./BridgeAdapterBase.sol";

contract EtherFiLiquidBridgeAdapter is BridgeAdapterBase {
    using SafeCast for uint256;

    // https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
    uint32 public constant DEST_EID_SCROLL = 30_214;

    event EtherFiLiquidTokenBridged(address indexed token, address indexed destRecipient, uint256 amount, uint32 destEid);
    error InvalidTeller();


    function bridge(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external payable override {
        // Silence compiler warning on unused variables.
        maxSlippage = maxSlippage;

        ILayerZeroTeller teller = ILayerZeroTeller(abi.decode(additionalData, (address)));
        if (address(teller.vault()) != token) revert InvalidTeller();
        
        bytes memory bridgeWildCard = abi.encode(DEST_EID_SCROLL);
        uint96 amount_U96 = amount.toUint96();
        uint256 fee = teller.previewFee(amount_U96, destRecipient, bridgeWildCard, ERC20(ETH));

        if (address(this).balance < fee) revert InsufficientNativeFee();

        teller.bridge{value: fee}(amount_U96, destRecipient, bridgeWildCard, ERC20(ETH), fee);

        emit EtherFiLiquidTokenBridged(token, destRecipient, amount, DEST_EID_SCROLL);
    }

    function getBridgeFee(address token, uint256 amount, address destRecipient, uint256 maxSlippage, bytes calldata additionalData) external view override returns (address, uint256) {
        // Silence compiler warning on unused variables.
        token = token;
        maxSlippage = maxSlippage;

        ILayerZeroTeller teller = ILayerZeroTeller(abi.decode(additionalData, (address)));
        bytes memory bridgeWildCard = abi.encode(DEST_EID_SCROLL);
        return (ETH, teller.previewFee(amount.toUint96(), destRecipient, bridgeWildCard, ERC20(ETH)));
    }
}