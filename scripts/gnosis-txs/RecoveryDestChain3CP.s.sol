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
import { RecoverySetConfigLib } from "../recovery/RecoverySetConfigLib.sol";

/**
 * @notice Generates 3CP JSON for one destination chain. Each bundle contains 4 calls:
 *         1. grantRole(PAUSER, operatingSafe)
 *         2. grantRole(UNPAUSER, operatingSafe)
 *         3. upgradeBeaconImplementation(TopUpV2 impl)
 *         4. dispatcher.setPeer(30111, AssetRecoveryModule on OP)
 *
 *         Covers every destination chain in the rollout (Gnosis, Polygon, opBNB, X-Layer). Run once
 *         per chain on that chain's RPC. Addresses come from deployments.json; the per-chain TopUpV2
 *         impl and the OP module are constants below.
 *
 *         opBNB additionally gets a 5th call — a receive-ULN endpoint.setConfig() pinning the 2-DVN
 *         quorum (no default DVN pathway OP<->opBNB), see RecoverySetConfigLib.
 *
 *         Polygon (137) is special: its canonical factory slot is a *reserved EtherFiPlaceholder*, so the
 *         bundle is prefixed with two atomic upgrades — placeholder -> TopUpFactory + reinitialize (wires
 *         the beacon), then -> canonical master impl (so no reinitializer persists) — before the standard
 *         calls (6 total). Default DVN, no setConfig.
 *
 * Usage:
 *   source .env && forge script scripts/gnosis-txs/RecoveryDestChain3CP.s.sol --rpc-url $<CHAIN>_RPC
 */
contract RecoveryDestChain3CP is GnosisHelpers, Utils, Test {
    bytes32 constant PAUSER = keccak256("PAUSER");
    bytes32 constant UNPAUSER = keccak256("UNPAUSER");

    address constant RECOVERY_MODULE_OP = 0x431d271D544aC67fAfFa8a9FfabAabCB14563102;

    // TopUpV2 impl addresses per chain (deployed via DeployTopUpV2Impl.s.sol).
    address constant TOPUP_V2_BASE     = 0xE6B694e38BDE2b3A577cCCd1BC9F80b8E1366AA2;
    address constant TOPUP_V2_ETH      = 0x80b1931D101a77a94b288a6Ce4F55A70E942ba28;
    address constant TOPUP_V2_ARB      = 0x35ED43Ffebde566C3c61311aa364858A180eC43A;
    address constant TOPUP_V2_BNB      = 0x25F89874d4831d166325c3d165C96b900bC7AB0D;
    address constant TOPUP_V2_HYPEREVM = 0x1abfE5B356e8D735D3e363b5DF5995A2a1012D0E;
    // Fill each after DeployTopUpV2Impl.s.sol runs on that chain (asserted non-zero below).
    address constant TOPUP_V2_GNOSIS   = address(0); // TODO: Gnosis (100)
    address constant TOPUP_V2_POLYGON  = 0xCB160aF093564E44Dc4c07bc03b828354E0fee77; // Polygon (137)
    address constant TOPUP_V2_OPBNB    = 0x5c301EF3307c9E2430c11e596e0306136B72f92D; // opBNB (204)

    // Polygon (137) only: its canonical factory slot (0xF4e147) is a reserved EtherFiPlaceholder, so the
    // dest bundle first upgrades it to a TopUpFactory + reinitializes (wires the beacon), then upgrades
    // back to the *current master* impl — atomically, so the reinitializer never persists on a live proxy.
    // Fill after the Polygon deploy (asserted non-zero for 137 below).
    //
    // IMPL SOURCES (must match, or the 3CP is not lead-compliant):
    //   POLYGON_REINIT_FACTORY_IMPL — TopUpFactory-with-reinitializer, deployed from the #136 branch
    //       (audit/topup-factory-reinitializer). Throwaway; NOT merged; discarded by upgrade B.
    //   POLYGON_MASTER_FACTORY_IMPL — CURRENT master TopUpFactory (no reinitializer), deployed via
    //       `forge create` from an origin/master checkout. Its runtime codehash MUST equal
    //       `forge inspect origin/master TopUpFactory` — this is the "upgrade back to current master".
    //   POLYGON_TOPUP_IMPL — base TopUp(WPOL) impl (arg to reinitialize); also from origin/master.
    address constant POLYGON_REINIT_FACTORY_IMPL = 0x706bF65A7B963C9e8ef81Ea41529eC7B0C1B9499; // from #136 (throwaway, not merged)
    address constant POLYGON_MASTER_FACTORY_IMPL = 0x70d7E0C93D8443325550Ba3F71576F5f346b8aA9; // from origin/master (current master, upgrade-back target)
    address constant POLYGON_TOPUP_IMPL          = 0xde8A2C33655ACA88f258988ED74D1511876343D1; // from origin/master (base TopUp, WPOL)

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
        require(topUpV2Impl != address(0), "TopUpV2 impl not set for this chain (deploy + fill the constant first)");

        string memory safe = addressToHex(RecoveryDeployConfig.OPERATING_SAFE);
        string memory txs = _getGnosisHeader(chainId, safe);

        // Polygon (137) only: reserved placeholder -> TopUpFactory, done atomically at the front of the
        // bundle so no reinitializer ever lives on a persisted impl:
        //   A. upgradeToAndCall(reinitImpl, reinitialize(topUpImpl))  -> wires the beacon
        //   B. upgradeToAndCall(masterImpl, "")                       -> swaps to the canonical impl
        if (block.chainid == 137) {
            require(
                POLYGON_REINIT_FACTORY_IMPL != address(0)
                    && POLYGON_MASTER_FACTORY_IMPL != address(0)
                    && POLYGON_TOPUP_IMPL != address(0),
                "fill Polygon impl constants after deploy"
            );
            // A. upgrade placeholder -> reinit impl, and reinitialize(topUpImpl) atomically
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(
                addressToHex(beaconFactory),
                iToHex(abi.encodeWithSignature(
                    "upgradeToAndCall(address,bytes)",
                    POLYGON_REINIT_FACTORY_IMPL,
                    abi.encodeWithSignature("reinitialize(address)", POLYGON_TOPUP_IMPL)
                )),
                "0", false
            )));
            // B. upgrade reinit impl -> canonical master TopUpFactory impl (reinitializer does not persist)
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(
                addressToHex(beaconFactory),
                iToHex(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", POLYGON_MASTER_FACTORY_IMPL, bytes(""))),
                "0", false
            )));
        }

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

        // 4. dispatcher.setPeer(OP_EID, AssetRecoveryModule) — last call unless a setConfig follows.
        bool needsSetConfig = RecoverySetConfigLib.needsSetConfig(block.chainid);
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(
            addressToHex(dispatcher),
            iToHex(abi.encodeWithSelector(IOAppCore.setPeer.selector, RecoveryDeployConfig.OP_EID, bytes32(uint256(uint160(RECOVERY_MODULE_OP))))),
            "0", !needsSetConfig
        )));

        // 5. (opBNB/X-Layer only) receive-ULN setConfig pinning the LZ Labs DVN.
        if (needsSetConfig) {
            (address t, bytes memory d) = RecoverySetConfigLib.destReceiveConfig(dispatcher, block.chainid);
            txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(t), iToHex(d), "0", true)));
        }

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
        if (block.chainid == 100)   return TOPUP_V2_GNOSIS;
        if (block.chainid == 137)   return TOPUP_V2_POLYGON;
        if (block.chainid == 204)   return TOPUP_V2_OPBNB;
        revert("unsupported chain");
    }
}
