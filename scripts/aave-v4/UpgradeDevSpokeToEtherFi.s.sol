// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

import { Utils } from "../utils/Utils.sol";
import { EtherFiSpokeInstanceDev } from "./EtherFiSpokeInstanceDev.sol";

/// @dev OZ v5 ProxyAdmin (auto-deployed by the spoke's TransparentUpgradeableProxy).
interface IProxyAdmin {
    function owner() external view returns (address);
    function upgradeAndCall(address proxy, address implementation, bytes calldata data) external payable;
}

/**
 * @title UpgradeDevSpokeToEtherFi
 * @notice Upgrades the dev Aave v4 test instance's spoke proxy (deployments/<env>/10/aave-v4-test.json)
 *         to EtherFiSpokeInstanceDev, the dev build of the prod whitelabel spoke: same one-line
 *         borrow gate (only ether.fi Cash Safes as position owner), dev EtherFiDataProvider constant.
 *         The new implementation re-bakes the immutables: same oracle as the live spoke, and
 *         MAX_USER_RESERVES_LIMIT = 64 to match prod (dev was uint16.max; dev lists 21 reserves,
 *         so no existing position can exceed the new limit).
 * @dev Storage-safe: between the pinned v0.5.11 and the fork launch branch the only core spoke
 *      change is `borrow` going external -> public virtual, and EtherFiSpokeInstanceDev adds no
 *      storage. No initializer is called (same SPOKE_REVISION). The new implementation links the
 *      canonical Aave-deployed LiquidationLogic (foundry.toml [profile.aave-deploy]) — the same
 *      library the prod instance links; the pre-upgrade dev impl linked a self-deployed copy.
 *
 * Usage (simulate by dropping --broadcast; the broadcast wallet must own the spoke's ProxyAdmin):
 *   source .env && ENV=dev FOUNDRY_PROFILE=aave-deploy forge script \
 *     scripts/aave-v4/UpgradeDevSpokeToEtherFi.s.sol:UpgradeDevSpokeToEtherFi \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract UpgradeDevSpokeToEtherFi is Utils {
    /// @dev Canonical Aave-deployed LiquidationLogic on OP Mainnet; must match the pin in
    ///      foundry.toml [profile.aave-deploy] libraries
    address constant LIQUIDATION_LOGIC = 0x88dF535473C5adf1f57789734A05E555F7Deb8DB;
    /// @dev ERC-1967 admin slot (eip1967.proxy.admin)
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    uint16 constant MAX_USER_RESERVES_LIMIT = 64; // prod whitelabel spoke value

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(vm.envOr("FOUNDRY_PROFILE", string("default")), "aave-deploy"), "Run with FOUNDRY_PROFILE=aave-deploy (library linking)");
        require(LIQUIDATION_LOGIC.code.length > 0, "Canonical LiquidationLogic has no code on this chain");

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/aave-v4-test.json"));
        address spoke = stdJson.readAddress(json, ".spoke");
        address oracle = ISpoke(spoke).ORACLE();
        require(oracle == stdJson.readAddress(json, ".aaveOracle"), "Live spoke oracle does not match the manifest");

        IProxyAdmin proxyAdmin = IProxyAdmin(address(uint160(uint256(vm.load(spoke, ADMIN_SLOT)))));
        address admin = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(proxyAdmin.owner() == admin, "Broadcast wallet does not own the spoke ProxyAdmin");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        EtherFiSpokeInstanceDev impl = new EtherFiSpokeInstanceDev(oracle, MAX_USER_RESERVES_LIMIT);
        proxyAdmin.upgradeAndCall(spoke, address(impl), "");
        vm.stopBroadcast();

        // Post-upgrade sanity through the proxy: immutables took, borrow gate is the dev one
        require(ISpoke(spoke).ORACLE() == oracle, "Oracle changed across the upgrade");
        require(EtherFiSpokeInstanceDev(spoke).ETHERFI_DATA_PROVIDER() == impl.ETHERFI_DATA_PROVIDER(), "Borrow gate data provider mismatch");

        console.log("New spoke implementation (EtherFiSpokeInstanceDev):", address(impl));
        console.log("Update aave-v4-test.json: spokeImpl + liquidationLogic =", LIQUIDATION_LOGIC);
    }
}
