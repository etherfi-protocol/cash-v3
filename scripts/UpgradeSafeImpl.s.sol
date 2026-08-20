// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiSafe } from "../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../src/safe/EtherFiSafeFactory.sol";
import { UpgradeableBeacon } from "../src/beacon-factory/BeaconFactory.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title UpgradeSafeImpl
 * @author ether.fi
 * @notice Deploys a new `EtherFiSafe` implementation and points the factory's beacon at it.
 *         One transaction upgrades EVERY safe on the chain at once.
 *
 * @dev Non-prod only. `upgradeBeaconImplementation` is `onlyRoleRegistryOwner`, and on OP prod
 *      that owner is the 8h `EtherFiTimelock` — use scripts/gnosis-txs/UpgradeSafeImplOP3CP.s.sol
 *      there. The ENV guard below is what stops this being run against prod by accident.
 *
 * @dev NEEDS A LINKED LIBRARY. `EtherFiSafe.isValidSignature` delegates to `SafeErc1271Lib`, a deployed
 *      library, so the implementation cannot be built without an address for it. Run
 *      scripts/DeploySafeErc1271Lib.s.sol first and pass the result via `--libraries`. Omitting it does
 *      not fail the build — forge deploys a throwaway library and links to that instead — so the
 *      post-deploy check below exercises the ERC-1271 path to prove the link actually resolves.
 *
 * Usage:
 *   ENV=dev forge script scripts/UpgradeSafeImpl.s.sol --rpc-url $RPC --account etherfi-dev --broadcast \
 *     --libraries src/libraries/SafeErc1271Lib.sol:SafeErc1271Lib:$SAFE_ERC1271_LIB
 */
contract UpgradeSafeImpl is Utils {
    using stdJson for string;

    function run() public {
        require(!isEqualString(getEnv(), "mainnet"), "ENV is mainnet (the default when unset) - set ENV=dev, or use gnosis-txs/UpgradeSafeImplOP3CP.s.sol for prod");

        string memory deployments = readDeploymentFile();
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");
        EtherFiSafeFactory safeFactory = EtherFiSafeFactory(deployments.readAddress(".addresses.EtherFiSafeFactory"));

        // Resolved by forge from --account / --private-key / --ledger.
        address deployer = msg.sender;

        // Fail before spending gas on an implementation the deployer cannot install.
        address owner = address(safeFactory.roleRegistry().owner());
        require(owner == deployer, "signer is not the RoleRegistry owner - it cannot upgrade the beacon");

        address oldImpl = UpgradeableBeacon(safeFactory.beacon()).implementation();

        vm.startBroadcast();
        EtherFiSafe safeImpl = new EtherFiSafe(dataProvider);
        safeFactory.upgradeBeaconImplementation(address(safeImpl));
        vm.stopBroadcast();

        require(UpgradeableBeacon(safeFactory.beacon()).implementation() == address(safeImpl), "beacon did not move to the new implementation");
        require(address(safeImpl.dataProvider()) == dataProvider, "implementation bound to a different EtherFiDataProvider");
        _assertErc1271LibraryIsLinked(address(safeImpl));

        console.log("old EtherFiSafe impl:", oldImpl);
        console.log("new EtherFiSafe impl:", address(safeImpl));
        console.log("WETH:                ", safeImpl.WETH());
        console.log("");
        console.log("Record the new impl under .addresses.EtherFiSafeImpl in the deployments file.");
    }

    /// @dev Proves the `SafeErc1271Lib` link resolves to live code. An empty signer set makes the library's
    ///      internal try/catch answer INVALID, which needs no owners and so works against a bare
    ///      implementation. If the linked address held no code the DELEGATECALL would return nothing and
    ///      decoding a bytes4 from it would revert, so this fails loudly either way.
    function _assertErc1271LibraryIsLinked(address impl) internal view {
        bytes memory message = "SafeErc1271Lib link check";
        bytes32 hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n25", message));
        bytes memory blob = abi.encode(message, new address[](0), new bytes[](0));

        require(EtherFiSafe(payable(impl)).isValidSignature(hash, blob) == bytes4(0xffffffff), "ERC-1271 path did not answer - SafeErc1271Lib is not linked to live code");
    }
}
