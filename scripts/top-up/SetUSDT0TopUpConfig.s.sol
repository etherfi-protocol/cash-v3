// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { USDT0TopUpConfig } from "../utils/USDT0TopUpConfig.sol";

/**
 * @title SetUSDT0TopUpConfig
 * @author ether.fi
 * @notice DEV-only EOA broadcast that wires a single chain's USD₮0 top-up rail into OP:
 *           COR-1757 — Arbitrum (42161): NEW rail, USDT0 has no route today (only CCTP USDC).
 *           COR-1759 — Ethereum (1):     re-point USDT from `optimismBridgeAdapter` (native L1
 *                                        bridge) to `oftBridgeAdapter` (USD₮0 OFT). Token stays
 *                                        legacy USDT; it now arrives on OP as USDT0.
 *           COR-1759 — HyperEVM (999):   collapse the existing two-hop USDT route (HyperEVM ->
 *                                        Ethereum TopUpSourceFactory -> OP) into a direct
 *                                        one-hop OFT send straight to OP.
 *
 *         Which rail is wired is selected by `block.chainid`, so this ONE script covers all
 *         three legs — point `--rpc-url` at the chain you want configured.
 *
 *         `setTokenConfig` is `onlyRoleRegistryOwner`; on dev the RoleRegistry owner is a
 *         broadcastable EOA on every one of these chains (verified 2026-09-23), so this is a
 *         plain broadcast — no Gnosis/timelock involved. The prod path is
 *         `scripts/gnosis-txs/SetUSDT0TopUpConfig3CP.s.sol`, which is NOT a plain Safe call: prod
 *         RoleRegistry ownership has moved to the 48h `EtherFiTimelock` on every chain here, see
 *         that script's natspec.
 *
 * Env: ENV=dev (asserted), PRIVATE_KEY (only for `run()`; not needed for `simulate()`)
 *
 * Usage — drop --broadcast to simulate the real entrypoint:
 *   ENV=dev PRIVATE_KEY=0x... forge script scripts/top-up/SetUSDT0TopUpConfig.s.sol \
 *     --rpc-url $ARBITRUM_RPC --broadcast   # COR-1757
 *   ENV=dev PRIVATE_KEY=0x... forge script scripts/top-up/SetUSDT0TopUpConfig.s.sol \
 *     --rpc-url $ETHEREUM_RPC --broadcast   # COR-1759 (Ethereum leg)
 *   ENV=dev PRIVATE_KEY=0x... forge script scripts/top-up/SetUSDT0TopUpConfig.s.sol \
 *     --rpc-url $HYPEREVM_RPC --broadcast   # COR-1759 (HyperEVM leg)
 *
 * Review-only dry run — no PRIVATE_KEY needed, never broadcasts, proves the call would succeed
 * and store the intended config by pranking the RoleRegistry's own live owner on a local fork:
 *   ENV=dev forge script scripts/top-up/SetUSDT0TopUpConfig.s.sol --sig "simulate()" --rpc-url $ARBITRUM_RPC
 */
contract SetUSDT0TopUpConfig is USDT0TopUpConfig, Test {
    using stdJson for string;

    /// @notice The real entrypoint: broadcasts from PRIVATE_KEY, which must already own the
    ///         RoleRegistry.
    function run() public {
        require(_isDev(), "SetUSDT0TopUpConfig: dev only - prod goes through scripts/gnosis-txs/SetUSDT0TopUpConfig3CP.s.sol");

        (TopUpFactory factory, TopUpFactory.TokenConfig memory config, Rail memory rail) = _prepare();

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(deployerPrivateKey);
        string memory deployments = readTopUpSourceDeployment();
        RoleRegistry roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        require(roleRegistry.owner() == broadcaster, "dev: broadcaster does not own the RoleRegistry");

        vm.startBroadcast(deployerPrivateKey);
        factory.setTokenConfig(_asArray(rail.token), _asArray(OP_CHAIN_ID), _asArray(config));
        vm.stopBroadcast();

        _assertConfigStored(factory, rail, config);
        _log(rail, recipient(config));
    }

    /// @notice Review-only: identical call, executed via `vm.prank` as the RoleRegistry's real
    ///         live owner instead of a broadcast key. Never touches the real chain (forge script
    ///         without `--broadcast` runs against a local fork) and needs no secret — the owner
    ///         address is public on-chain state, not a credential. Lets a reviewer confirm the
    ///         call succeeds and the config reads back correctly before anyone signs anything.
    function simulate() public {
        require(_isDev(), "SetUSDT0TopUpConfig: dev only");

        (TopUpFactory factory, TopUpFactory.TokenConfig memory config, Rail memory rail) = _prepare();

        string memory deployments = readTopUpSourceDeployment();
        RoleRegistry roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        address owner = roleRegistry.owner();

        vm.prank(owner);
        factory.setTokenConfig(_asArray(rail.token), _asArray(OP_CHAIN_ID), _asArray(config));

        _assertConfigStored(factory, rail, config);
        _log(rail, recipient(config));
        console.log("[simulate() only - nothing broadcast]");
    }

    function _prepare() internal view returns (TopUpFactory factory, TopUpFactory.TokenConfig memory config, Rail memory rail) {
        rail = _rail();
        _assertOftWiring(rail);

        string memory deployments = readTopUpSourceDeployment();
        factory = TopUpFactory(payable(deployments.readAddress(".addresses.TopUpSourceFactory")));
        address bridgeAdapter = _bridgeAdapter();
        address dest = _topUpDestOptimism();

        config = _tokenConfig(rail, bridgeAdapter, dest);
    }

    function recipient(TopUpFactory.TokenConfig memory config) internal pure returns (address) {
        return config.recipientOnDestChain;
    }

    function _log(Rail memory rail, address dest) internal view {
        console.log("ENV: dev, chainId:", block.chainid);
        console.log("%s -> Optimism top-up wired. token: %s", rail.name, rail.token);
        console.log("  oftAdapter:", rail.oftAdapter);
        console.log("  recipient: ", dest);
    }

    function _assertConfigStored(TopUpFactory factory, Rail memory rail, TopUpFactory.TokenConfig memory expected) internal view {
        TopUpFactory.TokenConfig memory stored = factory.getTokenConfig(rail.token, OP_CHAIN_ID);
        assertEq(stored.bridgeAdapter, expected.bridgeAdapter, "bridgeAdapter mismatch");
        assertEq(stored.recipientOnDestChain, expected.recipientOnDestChain, "recipientOnDestChain mismatch");
        assertEq(uint256(stored.maxSlippageInBps), uint256(expected.maxSlippageInBps), "maxSlippageInBps mismatch");
        assertEq(stored.additionalData, expected.additionalData, "additionalData mismatch");
    }
}
