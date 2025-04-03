// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {TopUpDest} from "../src/top-up/TopUpDest.sol";
import {TopUpDestWithMarkCompleteAdmin} from "../src/top-up/TopUpDestWithMarkCompleteAdmin.sol";
import {Utils, ChainConfig} from "./utils/Utils.sol";

contract UpgradeTopUpDest is Utils {
    bytes32[] txHashes;
    address[] users;
    uint256[] chainIds;
    address[] tokens;
    uint256[] amounts;

    function run() public {
        pushData();
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        string memory deployments = readDeploymentFile();

        address dataProvider = stdJson.readAddress(
            deployments,
            string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
        );
        UUPSUpgradeable topUpDest = UUPSUpgradeable(stdJson.readAddress(
            deployments, 
            string(abi.encodePacked(".", "addresses", ".", "TopUpDest"))
        ));

        TopUpDest topUpDestImpl = new TopUpDest(dataProvider);
        TopUpDestWithMarkCompleteAdmin topUpDestWithMarkCompleteAdminImpl = new TopUpDestWithMarkCompleteAdmin(dataProvider);

        topUpDest.upgradeToAndCall(address(topUpDestWithMarkCompleteAdminImpl), "");
        
        TopUpDestWithMarkCompleteAdmin topUpDestWithMarkCompleteAdmin = TopUpDestWithMarkCompleteAdmin(address(topUpDest));
        topUpDestWithMarkCompleteAdmin.markCompletedAdmin(txHashes, users, chainIds, tokens, amounts);

        topUpDest.upgradeToAndCall(address(topUpDestImpl), "");

        vm.stopBroadcast();
    }

    function pushData() internal {
        txHashes.push(0xf8d8ffc6ca5a0c8397e87e931c53a63d32a83b56d1deec042587ee030932c6fc);
        txHashes.push(0x9e91141c3596acc2c768e286dcaf3668797c413ef64a96bccb6031f389ad8a4b);
        txHashes.push(0x8752db99c3361df5793722dbee5a9057638e9e398fc40728d54927d2c13e0cf2);
        txHashes.push(0x66af6b04435647f7a39c6f9b2894bd3b303c88d1f6d162b889fcc82f39314197);
        txHashes.push(0x190e9b3644aea9b13c8e92b4d0298323eab0bba435c8f04252ea87f9c78d1593);
        txHashes.push(0x29b96d883cd580534a3a2868c282dc28422d98825e22018cc2f505f093fa1f80);
        txHashes.push(0x1b1b73cb62b52c2f2be45e93c3fb0ccd864bdbeb164e35ea7f3676e8ac1fbdbd);
        txHashes.push(0x0ecd88719e3e709378b1125a3c2d613b41415e4c2d36c753c03359305cfc08f6);
        txHashes.push(0xc4bd2c2a35199cac6e75af0345dc10589b3e788a82cac283202b73b666c2e941);
        txHashes.push(0x490bb8d1ab63e055990995a3449ebb110389c5277e5d489968bff889ba0e4849);
        txHashes.push(0x421b863eb0da393f9f0eecd19d26ad1c55ec88ec1e5555725d1345128f80a0a9);
        txHashes.push(0xb8c58b1d5c0ac9660da150db9cb734a3cf3b53f5bcd5eadaf0500183fe1cc280);
        txHashes.push(0xd7df16e7f51efedbdb589cbfb6eff9ede2b8ec3e4ea5c7e3779120fcc56cdf19);
        txHashes.push(0x66be1b6d8c156498ed0ca0eb241371bc775f33656e658cfc8be93878f1aa7dd7);
        txHashes.push(0xc3f7f495e57f869ebf6be400290a5829ae2e91919609881eeed60ca4cc6f18db);
        txHashes.push(0xc95e640476105dde5d7b0d9fc74f5c5fb29ee20895e1a4f531c0bd8ab724ef91);
        txHashes.push(0x6fb18da35c8932e4512c40f86e605e7d84565e6ec83cb25e8d5632c4ca0c188f);
        txHashes.push(0xec10136d2e1c1454458763182daa437af9b5fe37a27acd86f8ac6601c3c0fbb5);
        txHashes.push(0x4f91cbb9ea57b90b6245b38c66a56c1ba60d167b5a7dbc363f9149a644abb53f);

        users.push(0xf1Bc96d31eE1B161efD7886dd8145e896406482A);
        users.push(0x3B7232e7B355fe852B318347dE8F49Fe1A80cd7E);
        users.push(0xf1Bc96d31eE1B161efD7886dd8145e896406482A);
        users.push(0xd5CD38107E5c96574504E7Be11E5f30F17BFfB98);
        users.push(0x3B7232e7B355fe852B318347dE8F49Fe1A80cd7E);
        users.push(0x568fCacd4e3c26B1E98691A4750D366935154cB2);
        users.push(0xd9B39d97EaaB3e908D1941b681B8d22E4cfca171);
        users.push(0x2004BBD3Aaf891fe3C536686AeC17BEA97D346B8);
        users.push(0xd5CD38107E5c96574504E7Be11E5f30F17BFfB98);
        users.push(0xf1Bc96d31eE1B161efD7886dd8145e896406482A);
        users.push(0x6e5813E95Bc8Ce4FD3102844Ea88Cd0e1C8cda37);
        users.push(0x2004BBD3Aaf891fe3C536686AeC17BEA97D346B8);
        users.push(0xf1Bc96d31eE1B161efD7886dd8145e896406482A);
        users.push(0x568fCacd4e3c26B1E98691A4750D366935154cB2);
        users.push(0xd5CD38107E5c96574504E7Be11E5f30F17BFfB98);
        users.push(0xE8Ec2382fB25ff839217e575c213D8ba822aCf0B);
        users.push(0x3B7232e7B355fe852B318347dE8F49Fe1A80cd7E);
        users.push(0x6946E973dd42b42dac905AcEAD465E9a7cc0aeDC);
        users.push(0xf1Bc96d31eE1B161efD7886dd8145e896406482A);

        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);
        chainIds.push(8453);


        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
        tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);

        amounts.push(2000000);
        amounts.push(500000);
        amounts.push(1000000);
        amounts.push(100000);
        amounts.push(10000);
        amounts.push(10000);
        amounts.push(1000000);
        amounts.push(10000);
        amounts.push(100000);
        amounts.push(50000);
        amounts.push(20000);
        amounts.push(100000);
        amounts.push(2000000);
        amounts.push(130000);
        amounts.push(10000);
        amounts.push(100000000000000);
        amounts.push(100000);
        amounts.push(10000);
        amounts.push(2000000);
    }
}