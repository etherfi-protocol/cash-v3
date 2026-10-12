// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { StockWithdrawConfig } from "./StockWithdrawConfig.sol";
import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

/**
 * @title DeployStockUnwrapper
 * @notice Deploys the Ethereum-side StockUnwrapper (CREATE3 impl + CREATE3 UUPS proxy with
 *         atomic init) through the on-chain EtherFiDeployer, and grants
 *         STOCK_UNWRAPPER_ADMIN_ROLE.
 *
 *         The unwrapper initialises with the FULL config from `StockWithdrawConfig`: the
 *         OFTAdapter allowlist, and the trusted OP StockWithdrawModule PREDICTED from its
 *         CREATE3 salt (the EtherFiDeployer lives at the same address on every chain), so no
 *         cross-chain address plumbing is needed.
 *
 *         Two-actor flow, selected by ENV:
 *         - ENV=dev:      the broadcaster owns the RoleRegistry — the role grant is
 *                         broadcast directly.
 *         - ENV=mainnet:  the broadcaster only performs the unprivileged CREATE3 deploys. The
 *                         role grant ships in the Ethereum 3CP,
 *                         gnosis-txs/ConfigureStockRailEth3CP.s.sol, batched with the raw-stock
 *                         top-up token configs — same Safe, same owner-gated authority, so one
 *                         bundle and exactly one source of truth.
 *
 *         Nothing here is launch-blocking on the Ethereum side: the unwrapper's whole config
 *         (endpoint, source EID, trusted OP module, adapter allowlist) is set at `initialize`,
 *         and `pause()` is PAUSER-gated on the Ethereum RoleRegistry, which the Safe holds. The
 *         admin role buys later ADJUSTMENT (`configureAdapters`, `setSrcModule`) and the
 *         break-glass `rescueTokens`.
 *
 * The RoleRegistry is read from deployments/{ENV}/1/deployments.json; everything else comes
 * from StockWithdrawConfig.
 *
 * Env: PRIVATE_KEY (must be a registered EtherFiDeployer deployer), ENV (dev|mainnet)
 *
 * Run with --verify. After broadcast, run VerifyStockUnwrapper.s.sol against the live chain.
 */
contract DeployStockUnwrapper is StockWithdrawConfig {
    using stdJson for string;

    RoleRegistry internal roleRegistry;
    address internal unwrapperAdmin;
    address internal impl;
    address internal proxy;

    function run() public {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        string memory deployments = readDeploymentFile();
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPk);
        require(DEPLOYER.isDeployer(deployerAddress), "broadcaster is not an EtherFiDeployer deployer");

        address ownerBefore = roleRegistry.owner();
        unwrapperAdmin = _adminFor(deployerAddress);
        bool isDev = _isDev();

        // Fail before spending gas: the salts must resolve to the pinned prod addresses (the OP
        // module bakes THIS unwrapper's predicted address into its Ethereum route), and every
        // adapter in the launch set must lock a real ERC-4626 and be peered to the iToken the OP
        // side bridges — the adapter allowlist is what authenticates a compose.
        if (!isDev) _assertProdAddresses();
        _assertAssetRails(false);

        vm.startBroadcast(deployerPk);
        _deploy();
        if (isDev) {
            (bool ok,) = address(roleRegistry).call(_grantRoleData());
            require(ok, "grantRole failed");
        }
        vm.stopBroadcast();

        // Post-operation hook: the registry owner must be unchanged.
        require(roleRegistry.owner() == ownerBefore, "CRITICAL: role registry owner changed!");

        if (!isDev) {
            require(proxy == EXPECTED_PROD_UNWRAPPER_PROXY, "prod unwrapper did not land at the pinned address");
            require(impl == EXPECTED_PROD_UNWRAPPER_IMPL, "prod unwrapper impl did not land at the pinned address");
            require(StockUnwrapper(proxy).getSrcModule() == bytes32(uint256(uint160(EXPECTED_PROD_MODULE_PROXY))), "unwrapper trusts a different OP module");
        }

        console.log("StockUnwrapper impl:", impl);
        console.log("StockUnwrapper proxy:", proxy);

        if (!isDev) {
            console.log("");
            console.log("Next: record the proxy at .addresses.StockUnwrapper in deployments/mainnet/1/deployments.json,");
            console.log("then run scripts/gnosis-txs/ConfigureStockRailEth3CP.s.sol for the Ethereum 3CP bundle.");
        }
    }

    /// @dev CREATE3 deploys: impl + UUPS proxy with atomic init carrying the adapter
    ///      allowlist and the predicted OP module as the trusted compose sender.
    function _deploy() internal {
        impl = _create3(_unwrapperImplSalt(), type(StockUnwrapper).creationCode, "");

        (address[] memory adapters, bool[] memory registered) = _adapters();

        bytes memory initData = abi.encodeWithSelector(
            StockUnwrapper.initialize.selector,
            address(roleRegistry),
            LZ_ENDPOINT_ETHEREUM,
            OP_EID,
            _predictAddress(_moduleProxySalt()),
            adapters,
            registered
        );
        proxy = _create3(_unwrapperProxySalt(), type(UUPSProxy).creationCode, abi.encode(impl, initData));
    }

    /// @dev DEV ONLY: on dev the broadcaster owns the RoleRegistry, so the grant rides along
    ///      with the deploy. On prod it is its own 3CP (see the contract docs).
    function _grantRoleData() internal view returns (bytes memory) {
        return abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("ADMIN_TIMELOCK_ROLE"), unwrapperAdmin);
    }
}
