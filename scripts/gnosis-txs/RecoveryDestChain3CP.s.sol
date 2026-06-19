// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { BeaconFactory } from "../../src/top-up/TopUpFactory.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";
import { RecoveryDeployConfig } from "../recovery/RecoveryDeployConfig.sol";

/**
 * @notice Generates 3CP JSON for one destination chain. Each bundle contains 4 calls:
 *         1. grantRole(PAUSER, operatingSafe)
 *         2. grantRole(UNPAUSER, operatingSafe)
 *         3. upgradeBeaconImplementation(TopUpV2 impl)
 *         4. dispatcher.setPeer(30111, AssetRecoveryModule on OP)
 *
 * Run once per dest chain. Reads addresses from deployments.json, TopUpV2 impl
 * addresses and the OP module address are constants below.
 *
 * Usage:
 *   source .env && forge script scripts/gnosis-txs/RecoveryDestChain3CP.s.sol --rpc-url $BASE_RPC
 */
contract RecoveryDestChain3CP is GnosisHelpers, Utils, Test {
    bytes32 constant PAUSER = keccak256("PAUSER");
    bytes32 constant UNPAUSER = keccak256("UNPAUSER");

    address constant RECOVERY_MODULE_OP = 0x431d271D544aC67fAfFa8a9FfabAabCB14563102;

    // TopUpV2 impl addresses per chain (deployed via DeployTopUpV2Impl.s.sol)
    address constant TOPUP_V2_BASE     = 0xE6B694e38BDE2b3A577cCCd1BC9F80b8E1366AA2;
    address constant TOPUP_V2_ETH      = 0x80b1931D101a77a94b288a6Ce4F55A70E942ba28;
    address constant TOPUP_V2_ARB      = 0x35ED43Ffebde566C3c61311aa364858A180eC43A;
    address constant TOPUP_V2_BNB      = 0x25F89874d4831d166325c3d165C96b900bC7AB0D;
    address constant TOPUP_V2_HYPEREVM = 0x1abfE5B356e8D735D3e363b5DF5995A2a1012D0E;

    function run() public {
        string memory chainId = vm.toString(block.chainid);
        string memory deployments = readDeploymentFile();

        address roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));
        address beaconFactory = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "TopUpSourceFactory"));
        address dispatcher = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "AssetRecoveryDispatcher"));

        require(roleRegistry != address(0), "RoleRegistry not found");
        require(beaconFactory != address(0), "TopUpSourceFactory not found");
        require(dispatcher != address(0), "AssetRecoveryDispatcher not found");

        address topUpV2Impl = _getTopUpV2Impl();

        string memory safe = addressToHex(RecoveryDeployConfig.OPERATING_SAFE);
        string memory txs = _getGnosisHeader(chainId, safe);

        // 1. grantRole(PAUSER, operatingSafe)
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(roleRegistry),
            iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, PAUSER, RecoveryDeployConfig.OPERATING_SAFE)),
            "0", false
        )));

        // 2. grantRole(UNPAUSER, operatingSafe)
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(roleRegistry),
            iToHex(abi.encodeWithSelector(IRoleRegistry.grantRole.selector, UNPAUSER, RecoveryDeployConfig.OPERATING_SAFE)),
            "0", false
        )));

        // 3. upgradeBeaconImplementation(TopUpV2 impl)
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(beaconFactory),
            iToHex(abi.encodeWithSelector(BeaconFactory.upgradeBeaconImplementation.selector, topUpV2Impl)),
            "0", false
        )));

        // 4. dispatcher.setPeer(OP_EID, AssetRecoveryModule)
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(dispatcher),
            iToHex(abi.encodeWithSelector(IOAppCore.setPeer.selector, RecoveryDeployConfig.OP_EID, bytes32(uint256(uint160(RECOVERY_MODULE_OP))))),
            "0", true
        )));

        vm.createDir("./output", true);
        string memory path = string.concat("./output/Recovery3CP-dest-", chainId, ".json");
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        executeGnosisTransactionBundle(path);
        console.log("Simulation passed");
    }

    function _getTopUpV2Impl() internal view returns (address) {
        if (block.chainid == 8453)  return TOPUP_V2_BASE;
        if (block.chainid == 1)     return TOPUP_V2_ETH;
        if (block.chainid == 42161) return TOPUP_V2_ARB;
        if (block.chainid == 56)    return TOPUP_V2_BNB;
        if (block.chainid == 999)   return TOPUP_V2_HYPEREVM;
        revert("unsupported chain");
    }
}
