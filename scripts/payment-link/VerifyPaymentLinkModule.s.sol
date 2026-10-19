// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { PaymentLinkConfig } from "./PaymentLinkConfig.sol";

/**
 * @title VerifyPaymentLinkModule
 * @author ether.fi
 * @notice Read-only post-deployment verification for PaymentLinkModule on Optimism. Every check
 *         is a `require`, so any mismatch exits non-zero.
 *
 *         Checks: the pinned CREATE3 addresses, the EIP-1967 impl slot holding EXACTLY the
 *         predicted impl, the UpgradeableProxy roleRegistry slot holding our RoleRegistry
 *         (hijack detection), the proxy initialised and the impl's initializers disabled, the
 *         immutables (DataProvider, CashModule) and their cross-references, the EIP-712 domain,
 *         and the RoleRegistry owner (the 2-day upgrade timelock on prod). Then the wiring:
 *         - default (after enable): whitelisted on the DataProvider but NOT a default module,
 *           allowed to request withdrawals on the CashModule, launch fee set.
 *         - PAYMENT_LINK_VERIFY_DEPLOY_ONLY=true (between deploy and the enable 3CP): fee off and
 *           not yet registered anywhere.
 *         On dev it also reads the PROD DataProvider and CashModule and requires that the dev
 *         instance is registered on neither, so it can never pull from production safes.
 *
 * Env: ENV (dev|mainnet), PAYMENT_LINK_VERIFY_DEPLOY_ONLY (optional, default false),
 *      PAYMENT_LINK_DEV_FEE_RECEIVER (dev only; defaults to the dev RoleRegistry owner)
 *
 * Run: forge script scripts/payment-link/VerifyPaymentLinkModule.s.sol --rpc-url $OPTIMISM_RPC
 */
contract VerifyPaymentLinkModule is PaymentLinkConfig {
    function run() public view {
        require(block.chainid == OPTIMISM_CHAIN_ID, "This script must be run on Optimism (chain ID 10)");
        bool deployOnly = _deployOnly();
        Stack memory s = _currentStack();

        address proxy = _verifyDeployment(s);
        if (deployOnly) _verifyNotYetEnabled(s, proxy);
        else _verifyEnabled(s, proxy);
        if (_isDev()) _verifyNotOnProd(proxy);

        console.log("VerifyPaymentLinkModule: all checks passed");
        console.log("  ENV:  ", _env());
        console.log("  proxy:", proxy);
        console.log("  impl: ", _implOf(proxy));
        console.log("  stage:", deployOnly ? "deployed, not enabled" : "enabled");
    }

    /// @dev PAYMENT_LINK_VERIFY_DEPLOY_ONLY. Virtual for script tests.
    function _deployOnly() internal view virtual returns (bool) {
        return vm.envOr("PAYMENT_LINK_VERIFY_DEPLOY_ONLY", false);
    }

    /// @dev PAYMENT_LINK_DEV_FEE_RECEIVER, defaulting to the dev RoleRegistry owner (the dev
    ///      deploy sets the broadcaster as receiver). Virtual for script tests.
    function _devFeeReceiver(Stack memory s) internal view virtual returns (address) {
        return vm.envOr("PAYMENT_LINK_DEV_FEE_RECEIVER", s.roleRegistry.owner());
    }

    /// @dev Address, proxy-integrity, initialisation and immutable checks. Returns the proxy.
    function _verifyDeployment(Stack memory s) internal view returns (address proxy) {
        _assertPinnedAddresses();
        _assertStack(s);

        address expectedImpl = _predictAddress(_moduleImplSalt());
        proxy = _predictAddress(_moduleProxySalt());
        require(expectedImpl.code.length > 0, "impl not deployed");
        require(proxy.code.length > 0, "proxy not deployed");

        require(_implOf(proxy) == expectedImpl, "impl address mismatch - possible hijack");
        require(_registryOf(proxy) == address(s.roleRegistry), "roleRegistry mismatch - possible hijack");
        require(_initializedVersion(proxy) == 1, "proxy not initialised exactly once");
        require(_initializedVersion(expectedImpl) == type(uint64).max, "impl initializers not disabled");

        PaymentLinkModule module = PaymentLinkModule(proxy);
        PaymentLinkModule implModule = PaymentLinkModule(expectedImpl);
        require(address(module.roleRegistry()) == address(s.roleRegistry), "module.roleRegistry() mismatch");
        require(address(module.etherFiDataProvider()) == address(s.dataProvider), "module DataProvider mismatch");
        require(address(module.cashModule()) == address(s.cashModule), "module CashModule mismatch");
        require(address(module.cashModule()) == s.dataProvider.getCashModule(), "module CashModule != DataProvider.getCashModule()");
        require(address(implModule.etherFiDataProvider()) == address(s.dataProvider) && address(implModule.cashModule()) == address(s.cashModule), "impl immutables mismatch");
        require(module.MAX_FEE_BPS() == 100, "MAX_FEE_BPS mismatch");
        require(!module.paused(), "module is paused");

        bytes32 domain = keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"), keccak256("EtherFi PaymentLinkModule"), keccak256("1"), OPTIMISM_CHAIN_ID, proxy));
        require(module.DOMAIN_SEPARATOR() == domain, "EIP-712 domain mismatch");

        // Upgrade authority: on prod the RoleRegistry owner is the 2-day upgrade timelock.
        if (!_isDev()) require(s.roleRegistry.owner() == UPGRADE_TIMELOCK, "prod RoleRegistry owner is not the upgrade timelock");
    }

    function _verifyEnabled(Stack memory s, address proxy) internal view {
        require(s.dataProvider.isWhitelistedModule(proxy), "module not whitelisted on the DataProvider");
        require(!s.dataProvider.isDefaultModule(proxy), "module must not be a default module");
        require(_canRequestWithdraw(s.cashModule, proxy), "module cannot request withdrawals on the CashModule");

        (uint16 feeBps, address feeReceiver) = PaymentLinkModule(proxy).getFee();
        require(feeBps == LAUNCH_FEE_BPS, "fee mismatch");
        address expectedReceiver = _isDev() ? _devFeeReceiver(s) : PROD_FEE_RECEIVER;
        require(feeReceiver == expectedReceiver, "fee receiver mismatch");
    }

    function _verifyNotYetEnabled(Stack memory s, address proxy) internal view {
        (uint16 feeBps, address feeReceiver) = PaymentLinkModule(proxy).getFee();
        require(feeBps == DEPLOY_FEE_BPS && feeReceiver == DEPLOY_FEE_RECEIVER, "deploy-time fee config mismatch");
        require(!s.dataProvider.isWhitelistedModule(proxy), "module already whitelisted");
        require(!_canRequestWithdraw(s.cashModule, proxy), "module already allowed to request withdrawals");
    }

    /// @dev The dev instance must be invisible to the prod stack.
    function _verifyNotOnProd(address devProxy) internal view {
        Stack memory prod = _stack("mainnet");
        require(!prod.dataProvider.isWhitelistedModule(devProxy), "dev module is whitelisted on the PROD DataProvider");
        require(!prod.dataProvider.isDefaultModule(devProxy), "dev module is a default module on the PROD DataProvider");
        require(!_canRequestWithdraw(prod.cashModule, devProxy), "dev module can request withdrawals on the PROD CashModule");
        console.log("  [OK] dev instance is not registered on the prod DataProvider or CashModule");
    }
}
