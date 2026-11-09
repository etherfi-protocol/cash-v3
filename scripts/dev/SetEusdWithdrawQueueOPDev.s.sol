// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { IBoringOnChainQueue } from "../../src/interfaces/IBoringOnChainQueue.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title SetEusdWithdrawQueueOPDev
 * @notice Dev counterpart of SetEusdWithdrawQueueOP3CP: lets dev Cash safes on Optimism deposit eUSD and withdraw it
 *         to USDC through the eUSD BoringQueue, on the dev EtherFiLiquidModuleWithReferrer.
 *
 *         The role re-gating redeploy of the dev module carried over sETHFI only, so eUSD needs both its teller
 *         (addLiquidAssets, ADMIN_TIMELOCK_ROLE) and its queue (setLiquidAssetWithdrawQueue, RoleRegistry owner).
 *         On dev both are held by the deployer EOA, so this broadcasts directly. Each step is skipped when already
 *         applied.
 *
 * Usage:
 *   ENV=dev forge script scripts/dev/SetEusdWithdrawQueueOPDev.s.sol --rpc-url $OPTIMISM_RPC            (dry run)
 *   ENV=dev forge script scripts/dev/SetEusdWithdrawQueueOPDev.s.sol --rpc-url $OPTIMISM_RPC --broadcast
 */
contract SetEusdWithdrawQueueOPDev is Utils {
    using stdJson for string;

    address internal constant EUSD = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address internal constant EUSD_TELLER = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;
    address internal constant EUSD_QUEUE = 0xecAAd9C5A5988465Be116C3891B2EEf96Cb48C96;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

    function run() public {
        require(block.chainid == 10, "Optimism only");
        require(isEqualString(getEnv(), "dev"), "dev script: ENV must be dev");

        string memory deployments = readDeploymentFile();
        EtherFiDataProvider dataProvider = EtherFiDataProvider(deployments.readAddress(".addresses.EtherFiDataProvider"));
        RoleRegistry roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        EtherFiLiquidModule module = EtherFiLiquidModule(payable(deployments.readAddress(".addresses.EtherFiLiquidModuleWithReferrer")));

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        console.log("Signer:", signer);
        console.log("Dev EtherFiLiquidModuleWithReferrer:", address(module));

        require(address(module.etherFiDataProvider()) == address(dataProvider), "module bound to another data provider");
        require(address(dataProvider.roleRegistry()) == address(roleRegistry), "data provider bound to another RoleRegistry");
        require(dataProvider.isWhitelistedModule(address(module)), "module is not whitelisted");
        require(roleRegistry.owner() == signer, "signer is not the dev RoleRegistry owner");
        require(roleRegistry.hasRole(roleRegistry.ADMIN_TIMELOCK_ROLE(), signer), "signer lacks ADMIN_TIMELOCK_ROLE");

        require(address(IBoringOnChainQueue(EUSD_QUEUE).boringVault()) == EUSD, "queue is not the eUSD queue");
        require(IBoringOnChainQueue(EUSD_QUEUE).withdrawAssets(USDC).allowWithdraws, "eUSD queue does not allow USDC withdrawals");

        address teller = address(module.liquidAssetToTeller(EUSD));
        require(teller == address(0) || teller == EUSD_TELLER, "a different eUSD teller is set");
        address queue = module.liquidWithdrawQueue(EUSD);
        require(queue == address(0) || queue == EUSD_QUEUE, "a different eUSD queue is set");

        vm.startBroadcast(pk);
        if (teller == address(0)) {
            address[] memory assets = new address[](1);
            assets[0] = EUSD;
            address[] memory tellers = new address[](1);
            tellers[0] = EUSD_TELLER;
            module.addLiquidAssets(assets, tellers);
            console.log("  addLiquidAssets(eUSD, teller)");
        } else {
            console.log("  eUSD teller already set, skipped");
        }
        if (queue == address(0)) {
            module.setLiquidAssetWithdrawQueue(EUSD, EUSD_QUEUE);
            console.log("  setLiquidAssetWithdrawQueue(eUSD, queue)");
        } else {
            console.log("  eUSD queue already set, skipped");
        }
        vm.stopBroadcast();

        require(address(module.liquidAssetToTeller(EUSD)) == EUSD_TELLER, "eUSD teller not set");
        require(module.liquidWithdrawQueue(EUSD) == EUSD_QUEUE, "eUSD queue not set");
        console.log("  [OK] eUSD teller and withdraw queue set on the dev module");
    }
}
