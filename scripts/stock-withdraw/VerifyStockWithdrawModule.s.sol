// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { StockWithdrawConfig } from "./StockWithdrawConfig.sol";
import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";

/**
 * @notice Post-deployment verification for StockWithdrawModule on OP. Runs read-only against
 *         the live chain (AFTER the prod Gnosis wiring bundle has executed) and REVERTS on
 *         any mismatch (non-zero exit for CI/wrappers). Addresses come from
 *         deployments/{ENV}/10/deployments.json; everything else from StockWithdrawConfig.
 *
 * Env: ENV (dev|mainnet)
 *
 * Run: forge script scripts/stock-withdraw/VerifyStockWithdrawModule.s.sol --rpc-url <OP_RPC>
 */
contract VerifyStockWithdrawModule is StockWithdrawConfig {
    using stdJson for string;

    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // UpgradeableProxy ERC-7201 slot: first member is the roleRegistry address (hijack check).
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    function run() public view {
        require(block.chainid == 10, "This script must be run on Optimism (chain ID 10)");

        string memory deployments = readDeploymentFile();
        address roleRegistry = deployments.readAddress(".addresses.RoleRegistry");
        EtherFiDataProvider dataProvider = EtherFiDataProvider(deployments.readAddress(".addresses.EtherFiDataProvider"));
        ICashModule cashModule = ICashModule(deployments.readAddress(".addresses.CashModule"));

        address expectedImpl = _predictAddress(_moduleImplSalt());
        address proxy = _predictAddress(_moduleProxySalt());

        require(expectedImpl.code.length > 0, "impl not deployed");
        require(proxy.code.length > 0, "proxy not deployed");

        // EIP-1967 impl slot must contain the EXACT predicted CREATE3 impl address.
        address actualImpl = address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
        require(actualImpl == expectedImpl, "impl address mismatch - possible hijack");

        // Ownership: roleRegistry in storage must be OUR registry (hijack detection).
        address storedRegistry = address(uint160(uint256(vm.load(proxy, UPGRADEABLE_PROXY_STORAGE_SLOT))));
        require(storedRegistry == roleRegistry, "roleRegistry mismatch - possible hijack");

        StockWithdrawModule module = StockWithdrawModule(payable(proxy));

        // Immutable wiring on the implementation (read through the proxy).
        require(address(module.etherFiDataProvider()) == address(dataProvider), "dataProvider mismatch");

        // Initialized config: compose gas, provider fee, token set and the Ethereum route
        // pointing at the unwrapper's deterministic address.
        require(module.getComposeGasLimit() == COMPOSE_GAS_LIMIT, "composeGasLimit mismatch");

        (uint16 providerFeeBps, address feeReceiver) = module.getProviderFee();
        require(providerFeeBps == PROVIDER_FEE_BPS, "providerFeeBps mismatch");
        require(feeReceiver == FEE_RECEIVER, "feeReceiver mismatch");

        (address[] memory iTokens,) = _iTokens();
        for (uint256 i = 0; i < iTokens.length; i++) {
            require(module.isTokenSupported(iTokens[i]), "configured iToken not supported");
        }
        require(module.getStockUnwrapper(ETHEREUM_EID) == _predictAddress(_unwrapperProxySalt()), "Ethereum route unwrapper mismatch");

        // Wiring: default module on the DataProvider + withdraw-requester on the CashModule.
        require(dataProvider.isDefaultModule(proxy), "module is not a default module");

        address[] memory withdrawModules = cashModule.getWhitelistedModulesCanRequestWithdraw();
        bool canWithdraw;
        for (uint256 i = 0; i < withdrawModules.length; i++) {
            if (withdrawModules[i] == proxy) {
                canWithdraw = true;
                break;
            }
        }
        require(canWithdraw, "module cannot request withdrawals");

        console.log("VerifyStockWithdrawModule: all checks passed");
        console.log("  proxy:", proxy);
        console.log("  impl:", actualImpl);

        address[] memory tokens = module.getSupportedTokens();
        console.log("  supported tokens:", tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            console.log("   ", tokens[i]);
        }

        (uint32[] memory dstEids, address[] memory unwrappers) = module.getConfiguredUnwrappers();
        console.log("  configured routes:", dstEids.length);
        for (uint256 i = 0; i < dstEids.length; i++) {
            console.log("   ", dstEids[i], unwrappers[i]);
        }
    }
}
