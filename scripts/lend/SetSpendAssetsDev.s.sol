// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title SetSpendAssetsDev
 * @notice Adds USDT, frxUSD, liquidUSD, liquidRESERVE, EURC, and liquidEUR (weEUR) to the dev
 *         LendGateway's debit-spend set on Optimism
 * @dev Dev-only. A spend asset must first be a registered gateway reserve, so any asset not yet
 *      mirrored from the Aave Spoke is registered here (its reserveId resolved from the Spoke by
 *      underlying) before being flagged spendable. Idempotent: assets already registered and
 *      spendable are skipped, so the script can be re-run after a partial broadcast.
 *
 *      The CLI sender must hold LEND_GATEWAY_ADMIN_ROLE (the dev admin from DeployCashLendDev).
 *
 * Usage (drop --broadcast for simulation):
 *   source .env && ENV=dev forge script \
 *     scripts/lend/SetSpendAssetsDev.s.sol:SetSpendAssetsDev \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 */
contract SetSpendAssetsDev is Utils {
    // --- tokens (OP) ---
    address constant USDT = 0x94b008aA00579c1307B0EF2c499aD98a8ce58e58;
    address constant FRXUSD = 0x80Eede496655FB9047dd39d9f418d5483ED600df;
    address constant LIQUID_USD = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address constant LIQUID_RESERVE = 0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898;
    address constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    address constant LIQUID_EUR = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;

    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev");

        string memory record = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/", vm.toString(block.chainid), "/cash-lend.json"));
        LendGateway gateway = LendGateway(stdJson.readAddress(record, ".lendGateway"));
        IAaveV4Spoke spoke = IAaveV4Spoke(stdJson.readAddress(record, ".spoke"));

        string memory deployments = readDeploymentFile();
        RoleRegistry registry = RoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(registry.hasRole(gateway.LEND_GATEWAY_ADMIN_ROLE(), deployer), "sender missing LendGateway admin role");

        address[6] memory assets = [USDT, FRXUSD, LIQUID_USD, LIQUID_RESERVE, EURC, LIQUID_EUR];
        string[6] memory names = ["USDT", "frxUSD", "liquidUSD", "liquidRESERVE", "EURC", "liquidEUR"];

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        for (uint256 i = 0; i < assets.length; ++i) {
            if (!gateway.isRegistered(assets[i])) gateway.setReserveId(assets[i], _reserveIdOnSpoke(spoke, assets[i]));
            if (gateway.isSpendAsset(assets[i])) {
                console.log(string.concat(names[i], " already spendable, skipping"));
                continue;
            }
            gateway.setSpendAsset(assets[i], true);
            console.log(string.concat(names[i], " set as spend asset"));
        }

        vm.stopBroadcast();

        for (uint256 i = 0; i < assets.length; ++i) {
            require(gateway.isSpendAsset(assets[i]), string.concat(names[i], " is not spendable after run"));
        }
        console.log("All 6 spend assets configured on gateway:", address(gateway));
    }

    /// @dev Resolves an asset's Aave reserveId by scanning the Spoke's reserves for its underlying.
    function _reserveIdOnSpoke(IAaveV4Spoke spoke, address asset) internal view returns (uint256) {
        uint256 count = spoke.getReserveCount();
        for (uint256 reserveId = 0; reserveId < count; ++reserveId) {
            if (spoke.getReserve(reserveId).underlying == asset) return reserveId;
        }
        revert(string.concat("asset not a Spoke reserve: ", vm.toString(asset)));
    }
}
