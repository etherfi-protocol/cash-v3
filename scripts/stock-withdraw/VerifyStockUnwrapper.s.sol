// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

/**
 * @notice Post-deployment verification for StockUnwrapper on Ethereum. Runs read-only against
 *         the live chain and REVERTS on any mismatch (non-zero exit for CI/wrappers). The
 *         RoleRegistry is read from deployments/{ENV}/1/trading-account.json; the OP source
 *         module is predicted from its CREATE3 salt.
 *
 * Env: ENV (dev|mainnet)
 *
 * Run: forge script scripts/stock-withdraw/VerifyStockUnwrapper.s.sol --rpc-url <MAINNET_RPC>
 */
contract VerifyStockUnwrapper is EtherFiDeployerHelper {
    using stdJson for string;

    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // UpgradeableProxy ERC-7201 slot: first member is the roleRegistry address (hijack check).
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    string internal constant SALT_IMPL = "StockWithdraw.StockUnwrapperImpl";
    string internal constant SALT_PROXY = "StockWithdraw.StockUnwrapperProxy";
    string internal constant SALT_SRC_MODULE_PROXY = "StockWithdraw.StockWithdrawModuleProxy";

    /// @notice LayerZero V2 endpoint on Ethereum mainnet.
    address internal constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    /// @notice OP mainnet endpoint ID.
    uint32 internal constant SRC_EID = 30111;

    function run() public view {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        string memory tradingAccount = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/trading-account.json"));
        address roleRegistry = tradingAccount.readAddress(".RoleRegistry");

        address expectedImpl = _predictAddress(SALT_IMPL);
        address proxy = _predictAddress(SALT_PROXY);

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
        require(unwrapper.getLzEndpoint() == LZ_ENDPOINT, "lzEndpoint mismatch");
        require(unwrapper.getSrcEid() == SRC_EID, "srcEid mismatch");
        require(unwrapper.getSrcModule() == OFTComposeMsgCodec.addressToBytes32(_predictAddress(SALT_SRC_MODULE_PROXY)), "srcModule mismatch");

        console.log("VerifyStockUnwrapper: all checks passed");
        console.log("  proxy:", proxy);
        console.log("  impl:", actualImpl);

        address[] memory adapters = unwrapper.getRegisteredAdapters();
        console.log("  registered adapters:", adapters.length);
        for (uint256 i = 0; i < adapters.length; i++) {
            console.log("   ", adapters[i]);
        }
    }
}
