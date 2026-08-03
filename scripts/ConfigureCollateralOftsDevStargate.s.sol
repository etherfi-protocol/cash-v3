// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { StargateModule } from "../src/modules/stargate/StargateModule.sol";
import { ICashModule } from "../src/interfaces/ICashModule.sol";
import { IRoleRegistry } from "../src/interfaces/IRoleRegistry.sol";
import { Utils } from "./utils/Utils.sol";

/// @title ConfigureCollateralOftsDevStargate
/// @notice Wires the dev iwSPYx and iPAXG ShadowOFTs for cross-chain withdrawal from Optimism
///         via a direct EOA broadcast: registers both as OFT assets on StargateModule and
///         whitelists them as withdrawable on CashModule.
///
/// Usage:
///   source .env && ENV=dev forge script scripts/ConfigureCollateralOftsDevStargate.s.sol \
///     --rpc-url $OPTIMISM_RPC --broadcast --account deployer
contract ConfigureCollateralOftsDevStargate is Utils {
    // Dev iTOKEN ShadowOFTs on Optimism
    address constant IWSPYX = 0xCb4Ee509849AC1101b16556c658d6c48e5862fFA;
    address constant IPAXG = 0x56904d70E597e1D2D40853c61B6aA95622c70B0e;

    StargateModule stargateModule;
    ICashModule cashModule;
    IRoleRegistry roleRegistry;

    function run() public {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");

        string memory deployments = readDeploymentFile();
        stargateModule = StargateModule(payable(stdJson.readAddress(deployments, ".addresses.StargateModule")));
        cashModule = ICashModule(stdJson.readAddress(deployments, ".addresses.CashModule"));
        roleRegistry = IRoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));

        console.log("StargateModule:", address(stargateModule));
        console.log("CashModule:", address(cashModule));
        console.log("RoleRegistry:", address(roleRegistry));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        _ensureRole(cashModule.CASH_MODULE_CONTROLLER_ROLE(), deployer);
        _ensureRole(stargateModule.STARGATE_MODULE_ADMIN_ROLE(), deployer);

        _configureStargateAssets();
        _configureCashWithdrawable();

        vm.stopBroadcast();
    }

    /// @dev Grants `role` to `account` if missing and the deployer owns the RoleRegistry.
    function _ensureRole(bytes32 role, address account) internal {
        if (roleRegistry.hasRole(role, account)) return;
        require(roleRegistry.owner() == account, "deployer lacks role and does not own RoleRegistry");
        roleRegistry.grantRole(role, account);
    }

    /// @dev Registers both iTOKENs as OFT assets on StargateModule (pool == the OFT itself).
    ///      Skips entries that already match to keep re-runs cheap.
    function _configureStargateAssets() internal {
        address[] memory allAssets = new address[](2);
        allAssets[0] = IWSPYX;
        allAssets[1] = IPAXG;

        uint256 count;
        address[] memory pending = new address[](2);
        for (uint256 i = 0; i < allAssets.length; i++) {
            StargateModule.AssetConfig memory existing = stargateModule.getAssetConfig(allAssets[i]);
            if (!(existing.isOFT && existing.pool == allAssets[i])) {
                pending[count++] = allAssets[i];
            }
        }

        if (count == 0) {
            console.log("StargateModule asset config already up to date, skipping");
            return;
        }

        address[] memory assets = new address[](count);
        StargateModule.AssetConfig[] memory assetConfigs = new StargateModule.AssetConfig[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = pending[i];
            assetConfigs[i] = StargateModule.AssetConfig({ isOFT: true, pool: pending[i] });
        }

        stargateModule.setAssetConfig(assets, assetConfigs);
        console.log("StargateModule asset config set for", count, "asset(s)");
    }

    /// @dev Whitelists both iTOKENs as withdrawable on CashModule. The underlying whitelist
    ///      is already idempotent (no-op if already whitelisted), so this is safe to re-run.
    function _configureCashWithdrawable() internal {
        address[] memory withdrawableAssets = new address[](2);
        withdrawableAssets[0] = IWSPYX;
        withdrawableAssets[1] = IPAXG;

        bool[] memory shouldWhitelist = new bool[](2);
        shouldWhitelist[0] = true;
        shouldWhitelist[1] = true;

        cashModule.configureWithdrawAssets(withdrawableAssets, shouldWhitelist);
    }
}
