// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { StockWithdrawConfig } from "./StockWithdrawConfig.sol";
import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

/**
 * @notice Post-deployment verification for StockUnwrapper on Ethereum. Runs read-only against
 *         the live chain and REVERTS on any mismatch (non-zero exit for CI/wrappers). The
 *         RoleRegistry comes from deployments/{ENV}/1/deployments.json; everything else from
 *         StockWithdrawConfig (the OP source module is predicted from its CREATE3 salt).
 *
 * Env: ENV (dev|mainnet)
 *
 * Run: forge script scripts/stock-withdraw/VerifyStockUnwrapper.s.sol --rpc-url <MAINNET_RPC>
 */
contract VerifyStockUnwrapper is StockWithdrawConfig {
    using stdJson for string;

    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // UpgradeableProxy ERC-7201 slot: first member is the roleRegistry address (hijack check).
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    function run() public view {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        string memory deployments = readDeploymentFile();
        address roleRegistry = deployments.readAddress(".addresses.RoleRegistry");

        address expectedImpl = _predictAddress(_unwrapperImplSalt());
        address proxy = _predictAddress(_unwrapperProxySalt());

        require(expectedImpl.code.length > 0, "impl not deployed");
        require(proxy.code.length > 0, "proxy not deployed");

        // EIP-1967 impl slot must contain the EXACT predicted CREATE3 impl address.
        address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, "impl address mismatch - possible hijack");

        // Ownership: roleRegistry in storage must be OUR registry (hijack detection).
        address storedRegistry = address(uint160(uint256(vm.load(proxy, UPGRADEABLE_PROXY_STORAGE_SLOT))));
        require(storedRegistry == roleRegistry, "roleRegistry mismatch - possible hijack");

        StockUnwrapper unwrapper = StockUnwrapper(proxy);

        // Initialized config + cross-chain wiring.
        require(unwrapper.getLzEndpoint() == LZ_ENDPOINT_ETHEREUM, "lzEndpoint mismatch");
        require(unwrapper.getSrcEid() == OP_EID, "srcEid mismatch");
        require(unwrapper.getSrcModule() == OFTComposeMsgCodec.addressToBytes32(_predictAddress(_moduleProxySalt())), "srcModule mismatch");

        // Adapter allowlist set at initialize.
        (address[] memory adapters,) = _adapters();
        for (uint256 i = 0; i < adapters.length; i++) {
            require(unwrapper.isRegisteredAdapter(adapters[i]), "configured adapter not registered");
        }

        console.log("VerifyStockUnwrapper: all checks passed");
        console.log("  proxy:", proxy);
        console.log("  impl:", actualImpl);

        address[] memory registeredAdapters = unwrapper.getRegisteredAdapters();
        console.log("  registered adapters:", registeredAdapters.length);
        for (uint256 i = 0; i < registeredAdapters.length; i++) {
            console.log("   ", registeredAdapters[i]);
        }
    }
}
