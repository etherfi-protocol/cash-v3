// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiSafe } from "../src/safe/EtherFiSafe.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title DeploySafeImpl
 * @author ether.fi
 * @notice Deploys the `EtherFiSafe` implementation only. Pointing the factory beacon at it is a
 *         separate, privileged step: gnosis-txs/UpgradeSafeImplOP3CP.s.sol on prod (via the 8h
 *         timelock), UpgradeSafeImpl.s.sol on dev.
 *
 * @dev STEP 2 OF 2 after DeploySafeErc1271Lib.s.sol. `--libraries` must name the `SafeErc1271Lib`
 *      recorded in the deployments file — forge otherwise links a throwaway library it deploys on
 *      the fly, and that address is baked into the implementation's runtime code. The check below
 *      fails the run if the recorded address is not what got linked.
 *
 * Usage:
 *   forge script scripts/DeploySafeImpl.s.sol --rpc-url $RPC --account etherfi-dev --broadcast --verify \
 *     --libraries src/libraries/SafeErc1271Lib.sol:SafeErc1271Lib:<.addresses.SafeErc1271Lib>
 */
contract DeploySafeImpl is Utils {
    using stdJson for string;

    function run() public {
        string memory deployments = readDeploymentFile();
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        address erc1271Lib = deployments.readAddress(".addresses.SafeErc1271Lib");
        require(erc1271Lib.code.length > 0, "SafeErc1271Lib has no code at the recorded address");

        vm.startBroadcast();
        EtherFiSafe safeImpl = new EtherFiSafe(dataProvider);
        vm.stopBroadcast();

        require(_codeContainsAddress(address(safeImpl), erc1271Lib), "implementation not linked to the recorded SafeErc1271Lib - pass --libraries");
        require(address(safeImpl.dataProvider()) == dataProvider, "implementation bound to a different EtherFiDataProvider");

        console.log("new EtherFiSafe impl:", address(safeImpl));
        console.log("linked SafeErc1271Lib:", erc1271Lib);
        console.log("");
        console.log("The beacon still points at the old implementation until the upgrade step runs.");
    }

    /// @dev The linked library address appears verbatim in the runtime code at every call site, so a
    ///      plain byte search proves which library this build was linked against.
    function _codeContainsAddress(address target, address needle) internal view returns (bool) {
        bytes memory code = target.code;
        bytes20 want = bytes20(needle);
        for (uint256 i = 0; i + 20 <= code.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < 20; j++) {
                if (code[i + j] != want[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
