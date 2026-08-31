// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { Test } from "forge-std/Test.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @notice Generates the OP 3CP JSON that retires the eight superseded modules: the seven
 *         pre-lend modules 3CP-614 replaced ("old modules stay enabled for gradual migration")
 *         plus SafeAssetRecoveryModule v1, superseded by v2 in 3CP-617. Single tx from the
 *         OperatingSafe:
 *
 *           1. EtherFiDataProvider.configureModules([8 old modules], [false x 8])
 *           2. CashModule.configureModulesCanRequestWithdraw([old liquid, liquidReferrer, frax],
 *              [false x 3])
 *
 *         configureModules(false) removes each module from BOTH the whitelist and the default
 *         set, so EtherFiSafe.isModuleEnabled(old) turns false on every safe in one call. Tx 2
 *         clears the retired withdraw-requesters from CashModule's
 *         whitelistedModulesCanRequestWithdraw — 3CP-614 mirrored that status onto the
 *         replacements but left the old entries in place, and de-whitelisting on the
 *         DataProvider alone would leave the old addresses still treated as withdraw-request
 *         recipients (they bypass the whitelisted-recipient check in requestWithdrawal and skip
 *         cancellation on recipient-whitelist changes).
 *
 *         Old addresses are pinned as constants (deployments.json already points at the
 *         replacements, so they cannot be read from the file) and cross-checked at run time
 *         against the pre-lend deployment record in git (commit 65640df~1).
 *
 *         EXECUTION-ORDER REQUIREMENTS (must hold before signing):
 *         1. cash-be's chain registry must point safeAssetRecoveryModule at v2 and be deployed —
 *            its live recovery flow still uses the configured address; retiring v1 first breaks
 *            prod same-chain recovery.
 *         2. scripts/lend/check-pending-withdrawals.sh — a pending Cash withdrawal paying out to
 *            the old liquid / liquidReferrer / frax module would be stranded by retirement.
 *            NOTE: the script reads addresses from the CURRENT deployments json (now the new
 *            modules); scan for the old addresses below instead.
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
    address constant SAFE_ASSET_RECOVERY_V1 = 0x0AD7FDf0ED3BF0943753047B7C8F0922c624A6F2;

    function run() public {
        require(block.chainid == 10, "must be Optimism");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        string memory deployments = readDeploymentFile();
        EtherFiDataProvider dp = EtherFiDataProvider(stdJson.readAddress(deployments, ".addresses.EtherFiDataProvider"));
        ICashModule cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));
        address roleRegistry = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        address lendGateway = stdJson.readAddress(deployments, ".addresses.LendGateway");
        require(address(dp) != address(0), "EtherFiDataProvider not found");
        require(address(cashModule) != address(0), "CashModule not found");
        require(roleRegistry != address(0), "RoleRegistry not found");

        (address[] memory oldModules, string[8] memory names) = _oldModules();

        // The replacements now live under the same deployments.json keys; every one must be
        // whitelisted AND distinct from the module it replaced, or we're reading a stale file.
        string[8] memory newKeys = ["OpenOceanSwapModule", "EtherFiLiquidModule", "EtherFiLiquidModuleWithReferrer", "FraxModule", "EtherFiStakeModule", "MidasModule", "BeHYPEStakeModule", "SafeAssetRecoveryModule"];
        address[] memory newModules = new address[](8);
        for (uint256 i = 0; i < 8; i++) {
            newModules[i] = stdJson.readAddress(deployments, string.concat(".addresses.", newKeys[i]));
            require(newModules[i] != address(0) && newModules[i] != oldModules[i], "deployments.json still pre-upgrade");
            require(dp.isWhitelistedModule(newModules[i]), "replacement module not whitelisted - upgrade incomplete");
            require(dp.isWhitelistedModule(oldModules[i]), "old module already removed?");
        }

        // Old withdraw-requesters (3CP-614 mirrored this status onto the replacements but left
        // these entries live). Must currently be in the requester set or the file is stale.
        address[] memory oldRequesters = new address[](3);
        oldRequesters[0] = OLD_LIQUID;
        oldRequesters[1] = OLD_LIQUID_REFERRER;
        oldRequesters[2] = OLD_FRAX;
        for (uint256 i = 0; i < 3; i++) {
            require(_isRequester(cashModule, oldRequesters[i]), "old module not a withdraw-requester - already cleaned?");
        }

        bool[] memory flags = new bool[](8);
        // flags default to false — explicit loop omitted; configureModules(false) removes from
        // whitelist AND default set.

        string memory txs = _getGnosisHeader("10", addressToHex(OPERATING_SAFE));
        bytes memory callData = abi.encodeWithSelector(EtherFiDataProvider.configureModules.selector, oldModules, flags);
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(dp)), iToHex(callData), "0", false)));

        bytes memory requesterCallData = abi.encodeWithSelector(
            ICashModule.configureModulesCanRequestWithdraw.selector, oldRequesters, new bool[](3)
        );
        txs = string(abi.encodePacked(txs, _getGnosisTransaction(addressToHex(address(cashModule)), iToHex(requesterCallData), "0", true)));

        vm.createDir("./output", true);
        string memory path = "./output/RemoveOldLendModules3CP-op-10.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        address ownerBefore = IRoleRegistry(roleRegistry).owner();
        executeGnosisTransactionBundle(path);

        for (uint256 i = 0; i < 8; i++) {
            require(!dp.isWhitelistedModule(oldModules[i]), "SIM FAILED: old module still whitelisted");
            require(!dp.isDefaultModule(oldModules[i]), "SIM FAILED: old module still default");
            require(!_isRequester(cashModule, oldModules[i]), "SIM FAILED: old module still a withdraw-requester");
            require(dp.isWhitelistedModule(newModules[i]), "SIM FAILED: replacement lost whitelist");
            console.log("  removed %s: %s", names[i], oldModules[i]);
        }
        // Collateral damage guards: the gateway and the replacements' requester status stay live.
        require(_isRequester(cashModule, newModules[1]), "SIM FAILED: new liquid lost requester status");
        require(_isRequester(cashModule, newModules[2]), "SIM FAILED: new liquidReferrer lost requester status");
        require(_isRequester(cashModule, newModules[3]), "SIM FAILED: new frax lost requester status");
        if (lendGateway != address(0)) {
            require(dp.isDefaultModule(lendGateway), "SIM FAILED: LendGateway lost default status");
        }
        require(IRoleRegistry(roleRegistry).owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");

        console.log("Simulation passed");
    }

    function _isRequester(ICashModule cashModule, address module) internal view returns (bool) {
        address[] memory requesters = cashModule.getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < requesters.length; i++) {
            if (requesters[i] == module) return true;
        }
        return false;
    }

    function _oldModules() internal pure returns (address[] memory oldModules, string[8] memory names) {
        oldModules = new address[](8);
        oldModules[0] = OLD_OPEN_OCEAN;
        oldModules[1] = OLD_LIQUID;
        oldModules[2] = OLD_LIQUID_REFERRER;
        oldModules[3] = OLD_FRAX;
        oldModules[4] = OLD_STAKE;
        oldModules[5] = OLD_MIDAS;
        oldModules[6] = OLD_BEHYPE_STAKE;
        oldModules[7] = SAFE_ASSET_RECOVERY_V1;
        names = ["OpenOceanSwapModule", "EtherFiLiquidModule", "EtherFiLiquidModuleWithReferrer", "FraxModule", "EtherFiStakeModule", "MidasModule", "BeHYPEStakeModule", "SafeAssetRecoveryModule v1"];
    }
}
