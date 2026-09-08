// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { Utils } from "./utils/Utils.sol";

/**
 * @title DeploySafeErc1271Lib
 * @author ether.fi
 * @notice Deploys `SafeErc1271Lib`, the deployed library holding `EtherFiSafe.isValidSignature`'s body.
 *
 * @dev STEP 1 OF 2. `EtherFiSafe` references this library `external`ly, so solc leaves an unlinked
 *      placeholder in its bytecode and the address has to be supplied at build time. Deploy this first,
 *      record the address, then build the implementation with:
 *
 *        --libraries src/libraries/SafeErc1271Lib.sol:SafeErc1271Lib:<address>
 *
 * @dev WHY NOT LET FORGE AUTO-DEPLOY IT. `forge script` will happily deploy a missing library on the
 *      fly, but it picks a fresh address each run, and that address is baked into the implementation's
 *      runtime code. Two builds of identical source would then differ, which breaks the bytecode
 *      equality precheck in gnosis-txs/UpgradeSafeImplOP3CP.s.sol — the control that proves a prod
 *      implementation really is this repo's source. Pinning the address by hand keeps that check honest.
 *
 * @dev NOT pinned in foundry.toml on purpose: a repo-wide `libraries` entry would make every build and
 *      every test link to a mainnet address, and the library has no code there on a fresh test EVM or on
 *      a non-OP fork. Pass `--libraries` per invocation instead.
 *
 * Usage:
 *   forge script scripts/DeploySafeErc1271Lib.s.sol --rpc-url $RPC --account etherfi-dev --broadcast --verify
 */
contract DeploySafeErc1271Lib is Utils {
    function run() public {
        // A library cannot be instantiated with `new` (solc 1130), so deploy it from its artifact.
        vm.startBroadcast();
        address lib = vm.deployCode("SafeErc1271Lib.sol:SafeErc1271Lib");
        vm.stopBroadcast();

        require(lib.code.length > 0, "SafeErc1271Lib deployed without code");

        console.log("SafeErc1271Lib:", lib);
        console.log("");
        console.log("1. Record it under .addresses.SafeErc1271Lib in the deployments file for this chain.");
        console.log("2. Build the EtherFiSafe implementation against it:");
        console.log("   --libraries src/libraries/SafeErc1271Lib.sol:SafeErc1271Lib:<the address above>");
    }
}
