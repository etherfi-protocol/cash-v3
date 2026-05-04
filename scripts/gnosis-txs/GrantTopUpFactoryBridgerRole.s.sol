// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/// @title GrantTopUpFactoryBridgerRole (Gnosis)
/// @notice Generates a Gnosis Safe batch to grant TOPUP_FACTORY_BRIDGER_ROLE to bridger addresses
///         on TopUp source contracts across ETH mainnet, Base, Arbitrum, and HyperEVM.
///
/// Usage:
///   forge script scripts/gnosis-txs/GrantTopUpFactoryBridgerRole.s.sol:GrantTopUpFactoryBridgerRole --rpc-url <RPC> --broadcast
contract GrantTopUpFactoryBridgerRole is GnosisHelpers, Utils {
    address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    bytes32 public constant TOPUP_FACTORY_BRIDGER_ROLE = keccak256("TOPUP_FACTORY_BRIDGER_ROLE");

    function run() public {
        string memory deployments = readDeploymentFile();
        string memory chainId = vm.toString(block.chainid);

        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");

        address[] memory wallets = new address[](30);
        wallets[0]  = 0xf1eDbaEab4ad5F0d33d7E39D3C390588Ca44d2AE;
        wallets[1]  = 0x771b20098a9136964498c0C8E66F3037cDC3Cc29;
        wallets[2]  = 0xe8aACAC49C4645A92Ec2232eA33A8175c865A6bC;
        wallets[3]  = 0xf095e71886efaAa1d2CE66c3f9AA4cd4e8467CA9;
        wallets[4]  = 0xd0aBEFfC38Ac4374f66d62A75BF68D296cA63682;
        wallets[5]  = 0x3333e56c3C6231399F45B81A371E0d47c5E69EBD;
        wallets[6]  = 0xfCdA668F825ca1F973b1f241278239CFc4741B51;
        wallets[7]  = 0x1b1ea339AE1825Ec995e29A40cb8Ce497181dB82;
        wallets[8]  = 0x35f74aab2Bb462fD59bC27aDECf526aF5e646F1E;
        wallets[9]  = 0x7184D1A5a90c9A410bB7F597c12FC37a83D97DbC;
        wallets[10] = 0xEa7C228DeF6E373cd521eAe2A4Ec0Cf8c7a80Ba0;
        wallets[11] = 0xeb73e55348eC9C1cAf94c6dc519160af92769a39;
        wallets[12] = 0xaF84219269Fd1a464d780ecBf63c09576Ac7dDc6;
        wallets[13] = 0x944f8646918b17011a91257A9fF3DA31B845Ffad;
        wallets[14] = 0x779C8e07b291AA1407858E5bD77083bad7cFE23A;
        wallets[15] = 0x36cfB70A36d008908cD5AF5a94EA282872abAe88;
        wallets[16] = 0x82AB9B3EEa855EDeBcae33B20fAc3cC6800F3597;
        wallets[17] = 0xcA188e6eEdB2027e93900fB783DE6981651764A0;
        wallets[18] = 0x415fd807D411e0c10002431BE70A65F24f0B505c;
        wallets[19] = 0xAa1444bc78a57aa2F4157364cB4495A2ED328DF0;
        wallets[20] = 0xf96f8E03615f7b71e0401238D28bb08CceECBae7;
        wallets[21] = 0xB82C61E4A4b4E5524376BC54013a154b2e55C5c8;
        wallets[22] = 0xC73019F991dCBCc899d6B76000FdcCc99a208235;
        wallets[23] = 0x93D540Dd6893bF9eA8ECD57fce32cB49b2D1B510;
        wallets[24] = 0x29ebBC872CE1AF08508A65053b725Beadba43C48;
        wallets[25] = 0x957a670ecE294dDf71c6A9C030432Db013082fd1;
        wallets[26] = 0xFb5e703DAe21C594246f0311AE0361D1dFe250b1;
        wallets[27] = 0xab00819212917dA43A81b696877Cc0BcA798b613;
        wallets[28] = 0x5609BB231ec547C727D65eb6811CCd0C731339De;
        wallets[29] = 0xcf1369d6CdD148AF5Af04F4002dee9A00c7F8Ae9;

        vm.startBroadcast();

        string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

        for (uint256 i = 0; i < wallets.length; ++i) {
            bool isLast = i == wallets.length - 1;
            string memory grantRole = iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, TOPUP_FACTORY_BRIDGER_ROLE, wallets[i]));
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(roleRegistry), grantRole, "0", isLast)));
        }

        vm.createDir("./output", true);
        string memory path = string.concat("./output/GrantTopUpFactoryBridgerRole-", chainId, ".json");
        vm.writeFile(path, txs);

        vm.stopBroadcast();

        console.log("Generated gnosis tx granting TOPUP_FACTORY_BRIDGER_ROLE to %s wallets on chain %s", wallets.length, chainId);

        executeGnosisTransactionBundle(path);
    }
}
