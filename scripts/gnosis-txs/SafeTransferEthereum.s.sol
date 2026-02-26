// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

contract SafeTransferEthereum is GnosisHelpers, Utils, Test {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address destAddress = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;

    address wbtc = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address cbbtc = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address steth = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    function run() public {
        string memory chainId = vm.toString(block.chainid);

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        uint256 balanceWbtc = IERC20(wbtc).balanceOf(cashControllerSafe);
        uint256 balanceCbbtc = IERC20(cbbtc).balanceOf(cashControllerSafe);
        uint256 balanceSteth = IERC20(steth).balanceOf(cashControllerSafe);

        string memory transferWbtc = iToHex(abi.encodeWithSelector(IERC20.transfer.selector, destAddress, balanceWbtc));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(wbtc), transferWbtc, "0", false)));

        string memory transferCbbtc = iToHex(abi.encodeWithSelector(IERC20.transfer.selector, destAddress, balanceCbbtc));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(cbbtc), transferCbbtc, "0", false)));

        string memory transferSteth = iToHex(abi.encodeWithSelector(IERC20.transfer.selector, destAddress, balanceSteth));
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(steth), transferSteth, "0", true)));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/SafeTransferEthereum-", chainId, ".json");
        vm.writeFile(path, txs);

        executeGnosisTransactionBundle(path);
    }
}
