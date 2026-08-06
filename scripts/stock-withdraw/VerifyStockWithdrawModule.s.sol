// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";

/**
 * @notice Post-deployment verification for StockWithdrawModule on OP. Runs read-only against
 *         the live chain and REVERTS on any mismatch (non-zero exit for CI/wrappers).
 *
 * Env: ROLE_REGISTRY, ETHERFI_DATA_PROVIDER, DST_EID, COMPOSE_GAS_LIMIT
 *
 * Run: forge script scripts/stock-withdraw/VerifyStockWithdrawModule.s.sol --rpc-url <OP_RPC>
 */
contract VerifyStockWithdrawModule is Script {
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // UpgradeableProxy ERC-7201 slot: first member is the roleRegistry address (hijack check).
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    bytes32 public constant SALT_STOCK_WITHDRAW_MODULE_IMPL = keccak256("DeployStockWithdrawModule.StockWithdrawModuleImpl");
    bytes32 public constant SALT_STOCK_WITHDRAW_MODULE_PROXY = keccak256("DeployStockWithdrawModule.StockWithdrawModuleProxy");

    function run() public view {
        require(block.chainid == 10, "This script must be run on Optimism (chain ID 10)");

        address expectedImpl = CREATE3.predictDeterministicAddress(SALT_STOCK_WITHDRAW_MODULE_IMPL, NICKS_FACTORY);
        address proxy = CREATE3.predictDeterministicAddress(SALT_STOCK_WITHDRAW_MODULE_PROXY, NICKS_FACTORY);

        require(expectedImpl.code.length > 0, "impl not deployed");
        require(proxy.code.length > 0, "proxy not deployed");

        // EIP-1967 impl slot must contain the EXACT predicted CREATE3 impl address.
        address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, "impl address mismatch - possible hijack");

        // Ownership: roleRegistry in storage must be OUR registry (hijack detection).
        address storedRegistry = address(uint160(uint256(vm.load(proxy, UPGRADEABLE_PROXY_STORAGE_SLOT))));
        require(storedRegistry == vm.envAddress("ROLE_REGISTRY"), "roleRegistry mismatch - possible hijack");

        StockWithdrawModule module = StockWithdrawModule(payable(proxy));

        // Immutable wiring on the implementation (read through the proxy).
        require(address(module.etherFiDataProvider()) == vm.envAddress("ETHERFI_DATA_PROVIDER"), "dataProvider mismatch");

        // Initialized config.
        require(module.getDstEid() == uint32(vm.envUint("DST_EID")), "dstEid mismatch");
        require(module.getComposeGasLimit() == uint128(vm.envUint("COMPOSE_GAS_LIMIT")), "composeGasLimit mismatch");

        console.log("VerifyStockWithdrawModule: all checks passed");
        console.log("  proxy:", proxy);
        console.log("  impl:", actualImpl);
        console.log("  stockUnwrapper (0 until setDestination):", module.getStockUnwrapper());
    }
}
