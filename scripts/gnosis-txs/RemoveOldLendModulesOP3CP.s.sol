// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @notice Generates the OP 3CP JSON that retires the seven pre-lend modules 3CP-614 replaced
 *         ("old modules stay enabled for gradual migration"). Single tx from the OperatingSafe:
 *
 *           EtherFiDataProvider.configureModules([7 old modules], [false x 7])
 *
 *         configureModules(false) removes each module from BOTH the whitelist and the default
 *         set, so EtherFiSafe.isModuleEnabled(old) turns false on every safe in one call.
 *
 *         Old addresses are pinned as constants (deployments.json already points at the lend
 *         replacements, so they cannot be read from the file) and cross-checked at run time
 *         against the pre-lend deployment record in git (commit 65640df~1).
 *
 *         DELIBERATELY EXCLUDED: SafeAssetRecoveryModule v1 (0x0AD7FDf0…A6F2) — cash-be's live
 *         recovery flow still reads its configured module address, which points at v1. Retire it
 *         in a separate 3CP once cash-be's chain registry switches to v2.
 *
 *         PREFLIGHT (must pass before signing): scripts/lend/check-pending-withdrawals.sh —
 *         a pending Cash withdrawal paying out to the old liquid / liquidReferrer / frax module
 *         would be stranded by retirement. NOTE: the script reads addresses from the CURRENT
 *         deployments json (now the new modules); scan for the old addresses below instead.
 *
 * Usage:
 *   forge script scripts/gnosis-txs/RemoveOldLendModulesOP3CP.s.sol --rpc-url $OPTIMISM_RPC
 */
contract RemoveOldLendModulesOP3CP is GnosisHelpers, Utils, Test {
    address constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    // Pre-lend prod modules (deployments/mainnet/10/deployments.json @ 65640df~1)
    address constant OLD_OPEN_OCEAN      = 0x5765177E7A0226F6a9969770bd24CBd67950c375;
    address constant OLD_LIQUID          = 0x9008d1987A6aE5d3fFD9109967F85E631191E7A5;
    address constant OLD_LIQUID_REFERRER = 0x80D4B367659bb925A3790C76bC4da0B4f02d8613;
    address constant OLD_FRAX            = 0x6742AF68E4f45715480E06B81775Cdb5Ba167088;
    address constant OLD_STAKE           = 0xD908117461378323C68257d522DC2De5D7890A1B;
    address constant OLD_MIDAS           = 0x2D43400058cE6810916Fd312FB38a7DcdF9708aa;
    address constant OLD_BEHYPE_STAKE    = 0xd12efd5067DE109F9D00e1A31a34991d58DbB9F3;

    // Still-live modules that must remain untouched (sanity guard on the post-state)
    address constant SAFE_ASSET_RECOVERY_V1 = 0x0AD7FDf0ED3BF0943753047B7C8F0922c624A6F2;

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        string memory deployments = readDeploymentFile();
        EtherFiDataProvider dp = EtherFiDataProvider(stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider"));
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        address lendGateway = stdJson.readAddress(deployments, ".addresses.LendGateway");
        require(address(dp) != address(0), "EtherFiDataProvider not found");
        require(roleRegistry != address(0), "RoleRegistry not found");

        (address[] memory oldModules, string[7] memory names) = _oldModules();

        // The new replacements now live under the same deployments.json keys; every one must be
        // whitelisted AND distinct from the module it replaced, or we're reading a stale file.
        string[7] memory newKeys = ["OpenOceanSwapModule", "EtherFiLiquidModule", "EtherFiLiquidModuleWithReferrer", "FraxModule", "EtherFiStakeModule", "MidasModule", "BeHYPEStakeModule"];
        address[] memory newModules = new address[](7);
        for (uint256 i = 0; i < 7; i++) {
            newModules[i] = stdJson.readAddress(deployments, string.concat(".addresses.", newKeys[i]));
            require(newModules[i] != address(0) && newModules[i] != oldModules[i], "deployments.json still pre-lend");
            require(dp.isWhitelistedModule(newModules[i]), "replacement module not whitelisted - lend upgrade incomplete");
            require(dp.isWhitelistedModule(oldModules[i]), "old module already removed?");
        }

        bool[] memory flags = new bool[](7);
        // flags default to false — explicit loop omitted; configureModules(false) removes from
        // whitelist AND default set.

        string memory txs = _getGnosisHeader("10", addressToHex(OPERATING_SAFE));
        bytes memory callData = abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, oldModules, flags);
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(dp)), iToHex(callData), "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/RemoveOldLendModules3CP-op-10.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        address ownerBefore = IRoleRegistry(roleRegistry).owner();
        executeGnosisTransactionBundle(path);

        for (uint256 i = 0; i < 7; i++) {
            require(!dp.isWhitelistedModule(oldModules[i]), "SIM FAILED: old module still whitelisted");
            require(!dp.isDefaultModule(oldModules[i]), "SIM FAILED: old module still default");
            require(dp.isWhitelistedModule(newModules[i]), "SIM FAILED: replacement lost whitelist");
            console.log("  removed %s: %s", names[i], oldModules[i]);
        }
        // Collateral damage guards: everything else stays live.
        require(dp.isWhitelistedModule(SAFE_ASSET_RECOVERY_V1), "SIM FAILED: recovery v1 must NOT be touched here");
        if (lendGateway != address(0)) {
            require(dp.isDefaultModule(lendGateway), "SIM FAILED: LendGateway lost default status");
        }
        require(IRoleRegistry(roleRegistry).owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");

        console.log("Simulation passed");
    }

    function _oldModules() internal pure returns (address[] memory oldModules, string[7] memory names) {
        oldModules = new address[](7);
        oldModules[0] = OLD_OPEN_OCEAN;
        oldModules[1] = OLD_LIQUID;
        oldModules[2] = OLD_LIQUID_REFERRER;
        oldModules[3] = OLD_FRAX;
        oldModules[4] = OLD_STAKE;
        oldModules[5] = OLD_MIDAS;
        oldModules[6] = OLD_BEHYPE_STAKE;
        names = ["OpenOceanSwapModule", "EtherFiLiquidModule", "EtherFiLiquidModuleWithReferrer", "FraxModule", "EtherFiStakeModule", "MidasModule", "BeHYPEStakeModule"];
    }
}
