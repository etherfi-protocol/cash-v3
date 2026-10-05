// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { EtherFiSafe } from "../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../src/safe/EtherFiSafeFactory.sol";
import { ContractCodeChecker } from "./utils/ContractCodeChecker.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title VerifySafeWethWrapBytecode
 * @notice Verifies the Optimism safe WETH wrapping and ERC-1271 deployment against this source tree.
 *
 * @dev Set SAFE_ERC1271_LIB to `.addresses.SafeErc1271Lib` from the Optimism mainnet deployment
 *      file. The build must link `EtherFiSafe` to that exact deployed library address.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/VerifySafeWethWrapBytecode.s.sol \
 *     --rpc-url $OPTIMISM_RPC -vv \
 *     --libraries src/libraries/SafeErc1271Lib.sol:SafeErc1271Lib:$SAFE_ERC1271_LIB
 *
 * @dev The beacon check only reports rollout status. The script works before and after the timelock
 *      transaction executes.
 */
contract VerifySafeWethWrapBytecode is Utils, ContractCodeChecker {
    using stdJson for string;

    address internal constant OP_WETH = 0x4200000000000000000000000000000000000006;

    /// @notice Verifies the deployed library, safe implementation, and active beacon implementation.
    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        string memory deployments = readDeploymentFile();
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        address factory = deployments.readAddress(".addresses.EtherFiSafeFactory");
        address implementation = deployments.readAddress(".addresses.EtherFiSafeImpl");
        address erc1271Lib = deployments.readAddress(".addresses.SafeErc1271Lib");

        _verifyLibrary(erc1271Lib);
        _verifyImplementation(implementation, dataProvider, erc1271Lib);
        _reportBeaconState(factory, implementation);

        console2.log("Safe WETH wrap bytecode verification passed");
    }

    /// @dev Deploys the library artifact locally and reconciles its embedded self-address.
    function _verifyLibrary(address erc1271Lib) internal {
        address local = vm.deployCode("SafeErc1271Lib.sol:SafeErc1271Lib");
        requireCodeMatchAllowingAddressEmbeds("SafeErc1271Lib", erc1271Lib, local);
    }

    /// @dev Rebuilds the safe with production constructor inputs and requires an exact code match.
    function _verifyImplementation(address implementation, address dataProvider, address erc1271Lib) internal {
        require(_codeContainsAddress(implementation, erc1271Lib), "EtherFiSafeImpl not linked to recorded SafeErc1271Lib");

        EtherFiSafe local = new EtherFiSafe(dataProvider);
        requireExactCodeMatch("EtherFiSafeImpl", implementation, address(local));

        EtherFiSafe deployed = EtherFiSafe(payable(implementation));
        require(address(deployed.dataProvider()) == dataProvider, "EtherFiSafeImpl data provider mismatch");
        require(deployed.WETH() == OP_WETH, "EtherFiSafeImpl WETH mismatch");
    }

    /// @dev Reports whether the factory beacon already points to the verified implementation.
    function _reportBeaconState(address factory, address implementation) internal view {
        address beacon = EtherFiSafeFactory(factory).beacon();
        require(beacon.code.length > 0, "EtherFiSafe beacon has no code");

        address activeImplementation = UpgradeableBeacon(beacon).implementation();
        if (activeImplementation == implementation) {
            console2.log("  [OK] EtherFiSafe beacon uses verified implementation");
        } else {
            console2.log("  [PENDING] EtherFiSafe beacon implementation:", activeImplementation);
        }
    }
}
