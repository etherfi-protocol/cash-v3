// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { PaymentLinkConfig } from "./PaymentLinkConfig.sol";

/**
 * @title DeployPaymentLinkModule
 * @author ether.fi
 * @notice Deploys PaymentLinkModule on Optimism through the on-chain EtherFiDeployer: a CREATE3
 *         implementation and a CREATE3 UUPS proxy initialised in the SAME transaction
 *         (`initialize(roleRegistry, 0, address(0))`), so `initialize` cannot be front-run.
 *
 *         Two-actor flow, selected by ENV:
 *         - ENV=dev:      the broadcaster holds every role on the dev RoleRegistry, so the script
 *                         also wires the module into the DEV stack only: whitelisted (not default)
 *                         on the dev DataProvider, allowed to request withdrawals on the dev
 *                         CashModule, and the launch fee with the broadcaster as receiver.
 *         - ENV=mainnet:  only the unprivileged CREATE3 deploys. Enabling is the 3CP built by
 *                         scripts/gnosis-txs/EnablePaymentLinkModuleOP3CP.s.sol.
 *
 *         Idempotent: existing CREATE3 deployments are reused and dev wiring that is already in
 *         place is skipped, so a re-run changes nothing.
 *
 * Addresses (DataProvider, RoleRegistry, CashModule) come from deployments/{ENV}/10/deployments.json.
 *
 * Env: PRIVATE_KEY (a registered EtherFiDeployer deployer), ENV (dev|mainnet)
 *
 * Run (simulation; add --broadcast only for a real, approved deployment):
 *   ENV=dev forge script scripts/payment-link/DeployPaymentLinkModule.s.sol --rpc-url $OPTIMISM_RPC
 *
 * After broadcast run scripts/payment-link/VerifyPaymentLinkModule.s.sol and
 * scripts/payment-link/VerifyPaymentLinkBytecode.s.sol.
 */
contract DeployPaymentLinkModule is PaymentLinkConfig {
    Stack internal stack;
    address internal impl;
    address internal proxy;

    function run() public {
        require(block.chainid == OPTIMISM_CHAIN_ID, "This script must be run on Optimism (chain ID 10)");

        uint256 deployerPk = _deployerKey();
        address deployerAddress = vm.addr(deployerPk);
        require(DEPLOYER.isDeployer(deployerAddress), "broadcaster is not an EtherFiDeployer deployer");

        stack = _currentStack();
        _preflight();

        address ownerBefore = stack.roleRegistry.owner();

        vm.startBroadcast(deployerPk);
        _deploy();
        if (_isDev()) _wireDev(deployerAddress);
        vm.stopBroadcast();

        _postflight(deployerAddress);
        // Must be the last check: nothing in this run may have moved RoleRegistry ownership.
        require(stack.roleRegistry.owner() == ownerBefore, "CRITICAL: RoleRegistry owner changed");

        console.log("ENV:", _env());
        console.log("PaymentLinkModule impl: ", impl);
        console.log("PaymentLinkModule proxy:", proxy);
        if (!_isDev()) {
            console.log("");
            console.log("Next: run VerifyPaymentLinkModule.s.sol with PAYMENT_LINK_VERIFY_DEPLOY_ONLY=true,");
            console.log("then scripts/gnosis-txs/EnablePaymentLinkModuleOP3CP.s.sol to generate the enable 3CP.");
        }
    }

    /// @dev The broadcaster's key, from PRIVATE_KEY. Virtual for script tests.
    function _deployerKey() internal view virtual returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }

    /// @dev Pre-broadcast guards: pinned salts and a self-consistent stack for this ENV.
    function _preflight() internal view {
        _assertPinnedAddresses();
        _assertStack(stack);
    }

    /// @dev CREATE3 deploys: impl (immutable dataProvider + cashModule), then the UUPS proxy with
    ///      atomic init. Reuses either if it already has code.
    function _deploy() internal {
        impl = _create3(_moduleImplSalt(), type(PaymentLinkModule).creationCode, abi.encode(address(stack.dataProvider), address(stack.cashModule)));
        bytes memory initData = abi.encodeCall(PaymentLinkModule.initialize, (address(stack.roleRegistry), DEPLOY_FEE_BPS, DEPLOY_FEE_RECEIVER));
        proxy = _create3(_moduleProxySalt(), type(UUPSProxy).creationCode, abi.encode(impl, initData));
    }

    /// @dev DEV ONLY: the three enable calls, each skipped when already applied. On prod these
    ///      ship as the timelocked 3CP, because they need ADMIN_TIMELOCK_ROLE.
    function _wireDev(address devAdmin) internal {
        address[] memory modules = new address[](1);
        modules[0] = proxy;
        bool[] memory enable = new bool[](1);
        enable[0] = true;

        if (!stack.dataProvider.isWhitelistedModule(proxy)) stack.dataProvider.configureModules(modules, enable);
        if (!_canRequestWithdraw(stack.cashModule, proxy)) stack.cashModule.configureModulesCanRequestWithdraw(modules, enable);

        (uint16 feeBps, address feeReceiver) = PaymentLinkModule(proxy).getFee();
        if (feeBps != LAUNCH_FEE_BPS || feeReceiver != devAdmin) PaymentLinkModule(proxy).setFee(LAUNCH_FEE_BPS, devAdmin);
    }

    /// @dev The deployment landed where expected and the proxy is ours.
    function _postflight(address devAdmin) internal view {
        require(impl == _expectedImpl(), "impl did not land at the pinned address");
        require(proxy == _expectedProxy(), "proxy did not land at the pinned address");
        require(_implOf(proxy) == impl, "proxy impl slot != deployed impl");
        require(_registryOf(proxy) == address(stack.roleRegistry), "proxy roleRegistry != stack RoleRegistry - possible hijack");

        PaymentLinkModule module = PaymentLinkModule(proxy);
        require(address(module.etherFiDataProvider()) == address(stack.dataProvider), "module DataProvider mismatch");
        require(address(module.cashModule()) == address(stack.cashModule), "module CashModule mismatch");

        if (_isDev()) {
            require(stack.dataProvider.isWhitelistedModule(proxy), "dev: module not whitelisted");
            require(!stack.dataProvider.isDefaultModule(proxy), "dev: module must not be a default module");
            require(_canRequestWithdraw(stack.cashModule, proxy), "dev: module cannot request withdrawals");
            (uint16 feeBps, address feeReceiver) = module.getFee();
            require(feeBps == LAUNCH_FEE_BPS && feeReceiver == devAdmin, "dev: fee not set");
        }
    }
}
