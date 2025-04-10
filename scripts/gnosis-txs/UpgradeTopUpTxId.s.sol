// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.28;

// import {stdJson} from "forge-std/StdJson.sol";
// import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// import {TopUpDest} from "../../src/top-up/TopUpDest.sol";
// import {TopUpDestWithMarkCompleteAdmin} from "../../src/top-up/TopUpDestWithMarkCompleteAdmin.sol";
// import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
// import { Utils } from "../utils/Utils.sol";

// contract UpgradeTopUpTxId is GnosisHelpers, Utils {
//     address cashControllerSafe = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

//     bytes32[] txHashes;
//     address[] users;
//     uint256[] chainIds;
//     address[] tokens;
//     uint256[] amounts;

//     function run() public {
//         pushData();
//         string memory chainId = vm.toString(block.chainid);

//         vm.startBroadcast();

//         string memory txs = _getGnosisHeader(chainId, addressToHex(cashControllerSafe));

//         string memory deployments = readDeploymentFile();

//         address dataProvider = stdJson.readAddress(
//             deployments,
//             string(abi.encodePacked(".", "addresses", ".", "EtherFiDataProvider"))
//         );
//         UUPSUpgradeable topUpDest = UUPSUpgradeable(stdJson.readAddress(
//             deployments, 
//             string(abi.encodePacked(".", "addresses", ".", "TopUpDest"))
//         ));

//         TopUpDest topUpDestImpl = new TopUpDest(dataProvider);
//         TopUpDestWithMarkCompleteAdmin topUpDestWithMarkCompleteAdminImpl = new TopUpDestWithMarkCompleteAdmin(dataProvider);

//         string memory topUpWithCompletedAdminUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, topUpDestWithMarkCompleteAdminImpl, ""));
//         txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpDest)), topUpWithCompletedAdminUpgrade, false)));
        
//         string memory markCompletedTx = iToHex(abi.encodeWithSelector(TopUpDestWithMarkCompleteAdmin.markCompletedAdmin.selector, txHashes, users, chainIds, tokens, amounts));
//         txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpDest)), markCompletedTx, false)));

//         string memory topUpDestUpgrade = iToHex(abi.encodeWithSelector(UUPSUpgradeable.upgradeToAndCall.selector, topUpDestImpl, ""));
//         txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(topUpDest)), topUpDestUpgrade, true)));

//         vm.createDir("./output", true);
//         string memory path = "./output/UpgradeTopUpTxId.json";
//         vm.writeFile(path, txs);

//         vm.stopBroadcast();

//         /// below here is just a test
//         executeGnosisTransactionBundle(path);
//     }

//     // Dave will provide this data
//     function pushData() internal {
//         txHashes.push(0x5c770b3e69bc89606a4ec7dedcef67a1c5bea49ce5f644599efa557c63a6ea58);
//         txHashes.push(0xb15465396b9d0d3844b671f6790c1f85a726a567ef1620a366969d691719ddd0);
//         txHashes.push(0x45297138d6150f4757121c71793b8b8d7ddb85f2684df9a6bb447b109405d096);
//         txHashes.push(0xc75c64a6064f7c79463f19e0c746ba0a295eb5eb62d565bb21109590233dd605);
//         txHashes.push(0x3934f488e36868abb416328a79d7d19f4412a128876f2f63832e376d04f69f73);
//         txHashes.push(0x7b313b4f51d80a9a5b7d3627449e43fed65f3caac30b5f94ae25c001136e7ec8);
//         txHashes.push(0xbf4697ebc2045bca453934b7c1d5612d9ca427db7a46f36d3333ddfcc34821a7);
//         txHashes.push(0x590f8590c4677f3a4524ff7a988d1c306f4fe092eeb8724547ff99914cafda43);
//         txHashes.push(0xf36328d96f67a28fc444168dd9434f6f846aaf7cd4ab7c8b5f0d90cb36001975);

//         txHashes.push(0x21a0f7e8378b590e4531bd743e19d7b61ff5a79829a0209875e67fa568a9e2b1);
//         txHashes.push(0x122bc913a5d3168b253fe1c1105c134f33ebc23727f0d556a409a1f8b4428372);
//         txHashes.push(0x8aad99e137539d5f0ab282a372c64142db074af569ac6afd35573bf77cefd24f);
//         txHashes.push(0xb67286f619d2dbe3dfe045b88cab8333afd401a1f75f56e76e500722f0efcf5f);
//         txHashes.push(0x88fc97fb564fbda61f447e448ff44cd774749fcac19d62e01a9507815bf2799f);
//         txHashes.push(0x606368f38b058ab1063aa793f0870bb10c8d4f893fcda8812b955c3022185d66);
//         txHashes.push(0x7de49d05c52d9f99d418874c6017ca2c41a901e888b5bf72bcbd0682cbb31e7c);
//         txHashes.push(0xcf9c2c6ce737b5b89c774cd6118a2cc51391078129d32bcba322446be45f684a);
//         txHashes.push(0xce6f099b3820394d1543a74ce2e3692a1024b831126f21cd9b7169f4a5326cc4);
//         txHashes.push(0xa428350be7904714c6058471328cfe3c34dfea23e924a6cc8c2d684f4eff0ecd);
//         txHashes.push(0x7d90722fbaab010f5bf6bcfff5a27a5af54a51787b1e78443b736ae077557f10);
//         txHashes.push(0x3bc4f95854ad6fa7cd45c866fc6e3becd12281b6b529768734902224ba9a37e0);
//         txHashes.push(0x51f0b09679e49d3ebc27ec850d5bf8c2d45810b3c959ac9e8aa59058e07fe1a8);
//         txHashes.push(0x561c20a1a0c42bac38e23a1003dd0321a9c4f0a1b93c2df3d593cbd6c3f2872b);

//         chainIds.push(8453);
//         chainIds.push(8453);
//         chainIds.push(8453);
//         chainIds.push(8453);
//         chainIds.push(8453);
//         chainIds.push(8453);
//         chainIds.push(8453);
//         chainIds.push(8453);
//         chainIds.push(8453);
        
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);
//         chainIds.push(1);

//         users.push(0x711D45048FEa56c6aC41BeD7c5b14760B46A74Bc);
//         users.push(0x6845476D1b7c33F06EB8Bae361a46a9B8b9c9Ff2);
//         users.push(0x4ECF024b92f36C27F487dcb88cF109A6704ED643);
//         users.push(0x4ECF024b92f36C27F487dcb88cF109A6704ED643);
//         users.push(0x6845476D1b7c33F06EB8Bae361a46a9B8b9c9Ff2);
//         users.push(0x4ECF024b92f36C27F487dcb88cF109A6704ED643);
//         users.push(0x711D45048FEa56c6aC41BeD7c5b14760B46A74Bc);
//         users.push(0x711D45048FEa56c6aC41BeD7c5b14760B46A74Bc);
//         users.push(0xFcD3Ed46f0Aa1b6D6DF1c9dc0E87bb2891486f0b);

//         users.push(0x6845476D1b7c33F06EB8Bae361a46a9B8b9c9Ff2);
//         users.push(0x4ECF024b92f36C27F487dcb88cF109A6704ED643);
//         users.push(0x4ECF024b92f36C27F487dcb88cF109A6704ED643);
//         users.push(0x6b4e52334E15fb530a99130F6d7ff53fE6b0c8B0);
//         users.push(0x6b4e52334E15fb530a99130F6d7ff53fE6b0c8B0);
//         users.push(0x66ba083E4dE4ec303d856A0a6F51a89cd8e02eCD);
//         users.push(0x4ECF024b92f36C27F487dcb88cF109A6704ED643);
//         users.push(0x3D5b3E5d7A4818C54Df5a36A567E5ED663117B49);
//         users.push(0x3D5b3E5d7A4818C54Df5a36A567E5ED663117B49);
//         users.push(0x6b4e52334E15fb530a99130F6d7ff53fE6b0c8B0);
//         users.push(0x8AFfa2dE8C2A7fACb9626800ba3c7e2CEc5965D6);
//         users.push(0xAd91d6a7EAa11D4E825fA673fCe87341d36d37dE);
//         users.push(0x4ECF024b92f36C27F487dcb88cF109A6704ED643);
//         users.push(0x4ECF024b92f36C27F487dcb88cF109A6704ED643);

//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);

//         tokens.push(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
//         tokens.push(0xf0bb20865277aBd641a307eCe5Ee04E79073416C);
//         tokens.push(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
//         tokens.push(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);

//         amounts.push(50000);
//         amounts.push(25977121779781162);
//         amounts.push(50000000);
//         amounts.push(9401428791322719);
//         amounts.push(1000000);
//         amounts.push(94014287913227191);
//         amounts.push(1040000);
//         amounts.push(13000);
//         amounts.push(10000000);

//         amounts.push(60713212004187665);
//         amounts.push(20000000000);
//         amounts.push(500000000);
//         amounts.push(30000000);
//         amounts.push(100000000);
//         amounts.push(100000000);
//         amounts.push(10000000000000000);
//         amounts.push(10000000);
//         amounts.push(15000000000);
//         amounts.push(100000000);
//         amounts.push(1400000000);
//         amounts.push(10000000000000000);
//         amounts.push(10000000000000000);
//         amounts.push(100000000);

//     }
// }