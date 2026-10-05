// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { CashbackDistributor } from "../src/cashback-distributor/CashbackDistributor.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { CashbackDistributorConfig } from "./CashbackDistributorConfig.sol";

/**
 * @notice Post-deployment verification for CashbackDistributor on Optimism. Runs read-only
 *         against the live chain AFTER the DeployCashbackDistributor broadcast confirms, and
 *         REVERTS on any mismatch (non-zero exit for CI/wrappers). Every address is
 *         re-derived from the CREATE3 salts, so this catches a hijacked init, a swapped
 *         implementation, and wrong constructor/init args alike.
 * @dev Env: ENV (dev|mainnet); optionally CASHBACK_DISTRIBUTOR_RELAYER to also assert the
 *      relayer holds CASHBACK_DISTRIBUTOR_ROLE.
 *
 * Run: forge script scripts/VerifyCashbackDistributor.s.sol --rpc-url optimism
 */
contract VerifyCashbackDistributor is CashbackDistributorConfig {
    using stdJson for string;

    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // UpgradeableProxy ERC-7201 slot: first member is the roleRegistry address (hijack check).
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    function run() public view {
        require(block.chainid == 10, "This script must be run on Optimism (chain ID 10)");

        string memory deployments = readDeploymentFile();
        address roleRegistry = deployments.readAddress(".addresses.RoleRegistry");
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");

        address expectedImpl = _predictAddress(_implSalt());
        address proxy = _predictAddress(_proxySalt());

        require(expectedImpl.code.length > 0, "impl not deployed");
        require(proxy.code.length > 0, "proxy not deployed");

        // EIP-1967 impl slot must contain the EXACT predicted CREATE3 impl address.
        address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, "impl address mismatch - possible hijack");

        // Ownership: roleRegistry in storage must be OUR registry (hijack detection). A nonzero
        // value here also proves the atomic init ran.
        address storedRegistry = address(uint160(uint256(vm.load(proxy, UPGRADEABLE_PROXY_STORAGE_SLOT))));
        require(storedRegistry == roleRegistry, "roleRegistry mismatch - possible hijack");

        CashbackDistributor distributor = CashbackDistributor(proxy);

        // Immutables baked into the implementation at deploy (read through the proxy).
        require(distributor.ethfi() == ETHFI, "ethfi mismatch");
        require(distributor.sEthfi() == SETHFI, "sEthfi mismatch");
        require(address(distributor.etherFiDataProvider()) == dataProvider, "dataProvider mismatch");

        // Init-time config: the teller landed at initialize.
        require(distributor.teller() == SETHFI_TELLER, "teller mismatch");

        // Optional: assert the payout relayer holds the settlement role.
        address relayer = vm.envOr("CASHBACK_DISTRIBUTOR_RELAYER", address(0));
        if (relayer != address(0)) {
            require(RoleRegistry(roleRegistry).hasRole(distributor.CASHBACK_DISTRIBUTOR_ROLE(), relayer), "relayer missing CASHBACK_DISTRIBUTOR_ROLE");
        }

        console2.log("VerifyCashbackDistributor: all checks passed");
        console2.log("  proxy:", proxy);
        console2.log("  impl :", actualImpl);
        console2.log("  teller:", distributor.teller());
    }
}
