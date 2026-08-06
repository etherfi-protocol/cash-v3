// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

/**
 * @notice Post-deployment verification for StockUnwrapper on Ethereum. Runs read-only against
 *         the live chain and REVERTS on any mismatch (non-zero exit for CI/wrappers).
 *
 * Env: ROLE_REGISTRY, LZ_ENDPOINT, SRC_EID, SRC_MODULE, TRADING_SAFE_FACTORY
 *
 * Run: forge script scripts/stock-withdraw/VerifyStockUnwrapper.s.sol --rpc-url <MAINNET_RPC>
 */
contract VerifyStockUnwrapper is Script {
    address internal constant NICKS_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // UpgradeableProxy ERC-7201 slot: first member is the roleRegistry address (hijack check).
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    bytes32 public constant SALT_STOCK_UNWRAPPER_IMPL = keccak256("DeployStockUnwrapper.StockUnwrapperImpl");
    bytes32 public constant SALT_STOCK_UNWRAPPER_PROXY = keccak256("DeployStockUnwrapper.StockUnwrapperProxy");

    function run() public view {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        address expectedImpl = CREATE3.predictDeterministicAddress(SALT_STOCK_UNWRAPPER_IMPL, NICKS_FACTORY);
        address proxy = CREATE3.predictDeterministicAddress(SALT_STOCK_UNWRAPPER_PROXY, NICKS_FACTORY);

        require(expectedImpl.code.length > 0, "impl not deployed");
        require(proxy.code.length > 0, "proxy not deployed");

        // EIP-1967 impl slot must contain the EXACT predicted CREATE3 impl address.
        address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, "impl address mismatch - possible hijack");

        // Ownership: roleRegistry in storage must be OUR registry (hijack detection).
        address storedRegistry = address(uint160(uint256(vm.load(proxy, UPGRADEABLE_PROXY_STORAGE_SLOT))));
        require(storedRegistry == vm.envAddress("ROLE_REGISTRY"), "roleRegistry mismatch - possible hijack");

        StockUnwrapper unwrapper = StockUnwrapper(proxy);

        // Initialized config + cross-chain wiring.
        require(unwrapper.getLzEndpoint() == vm.envAddress("LZ_ENDPOINT"), "lzEndpoint mismatch");
        require(unwrapper.getSrcEid() == uint32(vm.envUint("SRC_EID")), "srcEid mismatch");
        require(unwrapper.getSrcModule() == OFTComposeMsgCodec.addressToBytes32(vm.envAddress("SRC_MODULE")), "srcModule mismatch");
        require(unwrapper.getTradingSafeFactory() == vm.envAddress("TRADING_SAFE_FACTORY"), "tradingSafeFactory mismatch");

        console.log("VerifyStockUnwrapper: all checks passed");
        console.log("  proxy:", proxy);
        console.log("  impl:", actualImpl);
    }
}
