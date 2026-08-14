// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { StockWrapProdConfig } from "./StockWrapProdConfig.sol";

/**
 * @title DeployProdStockWrapRedirectEth
 * @author ether.fi
 * @notice Deploys the two Ethereum **prod** implementations the raw-xStock redirect wrapping needs,
 *         and nothing else: a `TopUpFactory` impl carrying `wrapperFor` / `setRedirectWrappers`,
 *         and a `TopUpV2` impl for the beacon.
 *
 *         Both are plain implementation contracts — no proxy, no state, no privileged call — so
 *         this script is completely unprivileged and can be broadcast by any funded EOA. The three
 *         privileged calls that switch prod over live in
 *         scripts/gnosis-txs/StockWrapRedirectEth3CP.s.sol, and deliberately do NOT ride along
 *         here: on prod the RoleRegistry owner is the Safe, not this EOA.
 *
 * @dev WHY TopUpV2 AND NOT PLAIN TopUp. The Ethereum beacon currently runs plain `TopUp`, while
 *      chains 56 / 8453 / 42161 / 999 already run `TopUpV2`. This rollout has to replace the
 *      Ethereum beacon impl anyway, so it replaces it with V2 and Ethereum stops being the odd one
 *      out. V2 is `TopUp` plus `executeRecovery`: a dispatcher-gated sweep for funds stuck on the
 *      wrong chain, gated on an immutable `DISPATCHER` and refusing topup-supported tokens (those
 *      must use the normal claim path). Nothing about the wrap-on-redirect behaviour depends on V2;
 *      it rides along because the beacon slot is being touched regardless.
 *
 * Env: PRIVATE_KEY, ENV=mainnet
 *
 * Usage (simulate by dropping --broadcast):
 *   source .env && ENV=mainnet forge script \
 *     scripts/top-up/DeployProdStockWrapRedirectEth.s.sol:DeployProdStockWrapRedirectEth \
 *     --rpc-url $MAINNET_RPC --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
 *
 * After broadcast: VerifyStockWrapBytecode.s.sol, then the 3CP generator.
 */
contract DeployProdStockWrapRedirectEth is StockWrapProdConfig {
    using stdJson for string;

    function run() public {
        require(block.chainid == 1, "must run on Ethereum (1)");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        // Fail before spending gas: the V2 constructor arguments must be real contracts here, and
        // the dispatcher must answer to the same RoleRegistry as the factory it will serve.
        require(WETH.code.length > 0, "WETH has no code on this chain");
        require(RECOVERY_DISPATCHER.code.length > 0, "AssetRecoveryDispatcher has no code on this chain");

        string memory deployments = readTopUpSourceDeployment();
        IRoleRegistry roleRegistry = IRoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        require(address(TopUpFactory(payable(deployments.readAddress(".addresses.TopUpSourceFactory"))).roleRegistry()) == address(roleRegistry), "factory reads a different RoleRegistry than deployments.json records");

        address ownerBefore = roleRegistry.owner();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        address factoryImpl = address(new TopUpFactory());
        address topUpImpl = address(new TopUpV2(WETH, RECOVERY_DISPATCHER));
        vm.stopBroadcast();

        // The immutables are the whole reason V2 needs its own deploy per chain — read them back.
        require(TopUpV2(payable(topUpImpl)).DISPATCHER() == RECOVERY_DISPATCHER, "VERIFY FAILED: DISPATCHER mismatch");
        require(TopUpV2(payable(topUpImpl)).weth() == WETH, "VERIFY FAILED: weth mismatch");
        // Deploying an implementation must not touch governance.
        require(roleRegistry.owner() == ownerBefore, "CRITICAL: role registry owner changed!");

        console.log("TopUpFactory impl :", factoryImpl);
        console.log("TopUpV2 impl      :", topUpImpl);
        console.log("  weth            :", WETH);
        console.log("  dispatcher      :", RECOVERY_DISPATCHER);

        // These addresses are nonce-dependent, so downstream scripts read them from pinned
        // constants rather than a manifest. A fresh deploy that lands elsewhere must be pinned
        // before the 3CP bundle can name it.
        if (factoryImpl != TOPUP_FACTORY_IMPL || topUpImpl != TOPUP_V2_IMPL) {
            console.log("");
            console.log("ACTION REQUIRED: update TOPUP_FACTORY_IMPL / TOPUP_V2_IMPL in");
            console.log("scripts/top-up/StockWrapProdConfig.sol to the addresses above before");
            console.log("generating the 3CP bundle - the verifier and generator read those constants.");
        }

        console.log("");
        console.log("Next: ENV=mainnet forge script scripts/top-up/VerifyStockWrapBytecode.s.sol --rpc-url $MAINNET_RPC -vv");
        console.log("Then: forge script scripts/gnosis-txs/StockWrapRedirectEth3CP.s.sol --rpc-url $MAINNET_RPC");
    }
}
