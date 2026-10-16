// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { PaymentLinkConfig } from "./PaymentLinkConfig.sol";

/**
 * @title VerifyPaymentLinkBytecode
 * @author ether.fi
 * @notice Proves the code running at the PaymentLinkModule addresses is the code in THIS repo at
 *         THIS commit, built with the same constructor arguments. CREATE3 addresses prove who
 *         deployed, not what; this redeploys locally and compares runtime bytecode through
 *         `ContractCodeChecker`. Reverts on mismatch.
 * @dev The implementation is OZ `UUPSUpgradeable`, which embeds its own address (`__self`), so it
 *      goes through `requireCodeMatchAllowingAddressEmbeds`. Its other immutables
 *      (`etherFiDataProvider`, `cashModule`) are baked into runtime code, so a match also proves
 *      the live impl was constructed against OUR stack. The proxy embeds nothing and must match
 *      exactly. Full config checks stay in VerifyPaymentLinkModule.
 *
 * Env: ENV (dev|mainnet)
 *
 * Run: forge script scripts/payment-link/VerifyPaymentLinkBytecode.s.sol --rpc-url $OPTIMISM_RPC -vv
 */
contract VerifyPaymentLinkBytecode is PaymentLinkConfig, ContractCodeChecker {
    function run() public {
        require(block.chainid == OPTIMISM_CHAIN_ID, "This script must be run on Optimism (chain ID 10)");
        Stack memory s = _currentStack();

        address impl = _predictAddress(_moduleImplSalt());
        address proxy = _predictAddress(_moduleProxySalt());
        console.log("ENV:", _env());
        console.log("  PaymentLinkModule impl: ", impl);
        console.log("  PaymentLinkModule proxy:", proxy);

        address localImpl = address(new PaymentLinkModule(address(s.dataProvider), address(s.cashModule)));
        requireCodeMatchAllowingAddressEmbeds("PaymentLinkModuleImpl", impl, localImpl);
        requireExactCodeMatch("PaymentLinkModuleProxy", proxy, address(new UUPSProxy(localImpl, "")));

        require(_implOf(proxy) == impl, "PaymentLinkModule: proxy impl slot does not point at the verified impl - possible hijack");
        console.log("  [OK] proxy impl slot -> verified impl");
        console.log("");
        console.log("VerifyPaymentLinkBytecode: all bytecode checks passed");
    }
}
