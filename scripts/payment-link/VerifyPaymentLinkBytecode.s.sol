// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { PaymentLinkConfig } from "./PaymentLinkConfig.sol";

/**
 * @title VerifyPaymentLinkBytecode
 * @author ether.fi
 * @notice Proves the code running at the PaymentLinkModule addresses is the code in THIS repo at
 *         THIS commit, built with the same constructor arguments. CREATE3 addresses prove who
 *         deployed, not what; this redeploys locally and compares runtime bytecode. Reverts on
 *         mismatch.
 * @dev The implementation is OZ `UUPSUpgradeable`, which embeds its own address (`__self`) in
 *      several places; every copy in the local build is rebound to the deployed impl's address
 *      and the result must match exactly (`PaymentLinkConfig._requireImplCodeMatch`). Its other
 *      immutables (`etherFiDataProvider`, `cashModule`) are baked into runtime code, so a match
 *      also proves the live impl was constructed against OUR stack. The proxy embeds nothing and
 *      must match exactly. Full config checks stay in VerifyPaymentLinkModule.
 *
 * Env: ENV (dev|mainnet)
 *
 * Run: forge script scripts/payment-link/VerifyPaymentLinkBytecode.s.sol --rpc-url $OPTIMISM_RPC -vv
 */
contract VerifyPaymentLinkBytecode is PaymentLinkConfig {
    function run() public {
        require(block.chainid == OPTIMISM_CHAIN_ID, "This script must be run on Optimism (chain ID 10)");
        Stack memory s = _currentStack();

        address impl = _predictAddress(_moduleImplSalt());
        address proxy = _predictAddress(_moduleProxySalt());
        console.log("ENV:", _env());
        console.log("  PaymentLinkModule impl: ", impl);
        console.log("  PaymentLinkModule proxy:", proxy);

        _requireBuiltCode(s, impl, proxy);
        console.log("  [OK] proxy impl slot -> verified impl");
        console.log("");
        console.log("VerifyPaymentLinkBytecode: all bytecode checks passed");
    }
}
