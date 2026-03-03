// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SafeTransferArbitrum is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address destAddress = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;

    address usdce = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    address usdt0 = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    function run() public {
        string memory chainId = vm.toString(block.chainid);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        uint256 balanceUsdce = IERC20(usdce).balanceOf(cashControllerSafe);
        uint256 balanceUsdt0 = IERC20(usdt0).balanceOf(cashControllerSafe);

        string memory transferUsdce = iToHex(abi.encodeWithSelector(IERC20.transfer.selector, destAddress, balanceUsdce));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(usdce), transferUsdce, "0", false)));

        string memory transferUsdt0 = iToHex(abi.encodeWithSelector(IERC20.transfer.selector, destAddress, balanceUsdt0));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(usdt0), transferUsdt0, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/SafeTransferArbitrum-", chainId, ".json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}
