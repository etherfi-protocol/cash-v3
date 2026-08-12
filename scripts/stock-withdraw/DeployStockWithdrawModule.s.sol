// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { StockWithdrawConfig } from "./StockWithdrawConfig.sol";
import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";

/**
 * @title DeployStockWithdrawModule
 * @notice Deploys the OP-side StockWithdrawModule (CREATE3 impl + CREATE3 UUPS proxy with
 *         atomic init) through the on-chain EtherFiDeployer. On DEV it also wires the module
 *         up as a DEFAULT module on the EtherFiDataProvider, as a withdraw-requester on the
 *         CashModule, and grants STOCK_WITHDRAW_MODULE_ADMIN_ROLE.
 *
 *         The module initialises with the FULL config from `StockWithdrawConfig`: the
 *         supported ShadowOFTs and the Ethereum route pointing at the StockUnwrapper's
 *         PREDICTED CREATE3 address (the EtherFiDeployer lives at the same address on every
 *         chain, so the mainnet address is derivable before that deploy runs).
 *
 *         Two-actor flow, selected by ENV:
 *         - ENV=dev:      the broadcaster holds the admin roles (dev admin owns the
 *                         RoleRegistry), so deploys AND wiring are broadcast directly.
 *         - ENV=mainnet:  this script ONLY performs the unprivileged CREATE3 deploys. The
 *                         privileged wiring is NOT emitted here — `grantRole` is owner-gated
 *                         and the RoleRegistry owner is the 8h EtherFiTimelock, so the wiring
 *                         is a two-step schedule -> execute rollout built by
 *                         scripts/gnosis-txs/EnableStockWithdrawModuleOP3CP.s.sol. Keeping one
 *                         source of truth stops a stale single-bundle version of the wiring
 *                         (whose grantRole leg now reverts) from being signed by mistake.
 *
 * Rollout order:
 *   1. OP:  this script — run with --verify.
 *   2. OP:  prod only — record the proxy at .addresses.StockWithdrawModule in deployments.json,
 *           then EnableStockWithdrawModuleOP3CP.s.sol for the two 3CP bundles (8h apart).
 *   3. ETH: DeployStockUnwrapper — run with --verify (prod: then execute its bundle).
 *   4. Further tokens/adapters/routes are added later via the admin setters.
 *
 * Addresses (DataProvider, RoleRegistry, CashModule) are read from
 * deployments/{ENV}/10/deployments.json; everything else comes from StockWithdrawConfig.
 *
 * Env: PRIVATE_KEY (must be a registered EtherFiDeployer deployer), ENV (dev|mainnet)
 *
 * STOCK_WITHDRAW_MODULE_ADMIN_ROLE goes to the broadcaster on dev, and to the prod Safe on
 * mainnet.
 *
 * After broadcast (and bundle execution on prod), run VerifyStockWithdrawModule.s.sol.
 */
contract DeployStockWithdrawModule is StockWithdrawConfig {
    using stdJson for string;

    EtherFiDataProvider internal dataProvider;
    RoleRegistry internal roleRegistry;
    ICashModule internal cashModule;
    address internal moduleAdmin;
    address internal impl;
    address internal proxy;

    function run() public {
        require(block.chainid == 10, "This script must be run on Optimism (chain ID 10)");

        string memory deployments = readDeploymentFile();
        dataProvider = EtherFiDataProvider(deployments.readAddress(".addresses.EtherFiDataProvider"));
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        cashModule = ICashModule(deployments.readAddress(".addresses.CashModule"));

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPk);
        require(DEPLOYER.isDeployer(deployerAddress), "broadcaster is not an EtherFiDeployer deployer");

        moduleAdmin = _adminFor(deployerAddress);
        bool isDev = _isDev();

        vm.startBroadcast(deployerPk);
        _deploy();
        if (isDev) _wireDirectly();
        vm.stopBroadcast();

        console.log("StockWithdrawModule impl:", impl);
        console.log("StockWithdrawModule proxy:", proxy);

        if (!isDev) {
            console.log("");
            console.log("Next: record the proxy at .addresses.StockWithdrawModule in deployments/mainnet/10/deployments.json,");
            console.log("then run scripts/gnosis-txs/EnableStockWithdrawModuleOP3CP.s.sol to generate the 3CP wiring bundles.");
        }
    }

    /// @dev CREATE3 deploys: impl (immutable dataProvider) + UUPS proxy with atomic init
    ///      carrying the full token + route config. The Ethereum route targets the
    ///      unwrapper's PREDICTED address — deployed right after this script.
    function _deploy() internal {
        impl = _create3(_moduleImplSalt(), type(StockWithdrawModule).creationCode, abi.encode(address(dataProvider)));

        (address[] memory iTokens, bool[] memory supported) = _iTokens();

        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = ETHEREUM_EID;
        address[] memory unwrappers = new address[](1);
        unwrappers[0] = _predictAddress(_unwrapperProxySalt());

        bytes memory initData = abi.encodeCall(StockWithdrawModule.initialize, (StockWithdrawModule.InitParams({
            roleRegistry: address(roleRegistry),
            lzReceiveGasLimit: LZ_RECEIVE_GAS_LIMIT,
            composeGasLimit: COMPOSE_GAS_LIMIT,
            providerFeeBps: PROVIDER_FEE_BPS,
            feeReceiver: FEE_RECEIVER,
            iTokens: iTokens,
            supported: supported,
            dstEids: dstEids,
            unwrappers: unwrappers
        })));
        proxy = _create3(_moduleProxySalt(), type(UUPSProxy).creationCode, abi.encode(impl, initData));
    }

    /// @dev The three privileged wiring calls. DEV ONLY — on prod these ship as the two 3CP
    ///      bundles built by scripts/gnosis-txs/EnableStockWithdrawModuleOP3CP.s.sol, because
    ///      `grantRole` is owner-gated and the owner is the 8h EtherFiTimelock.
    function _wiringCalls() internal view returns (address[3] memory targets, bytes[3] memory payloads) {
        address[] memory modules = new address[](1);
        modules[0] = proxy;
        bool[] memory enable = new bool[](1);
        enable[0] = true;

        targets[0] = address(dataProvider);
        payloads[0] = abi.encodeWithSelector(EtherFiDataProvider.configureDefaultModules.selector, modules, enable);
        targets[1] = address(cashModule);
        payloads[1] = abi.encodeWithSelector(ICashModule.configureModulesCanRequestWithdraw.selector, modules, enable);
        targets[2] = address(roleRegistry);
        payloads[2] = abi.encodeWithSignature("grantRole(bytes32,address)", StockWithdrawModule(payable(proxy)).STOCK_WITHDRAW_MODULE_ADMIN_ROLE(), moduleAdmin);
    }

    /// @dev Dev: the broadcaster holds the roles — execute the wiring in-broadcast.
    function _wireDirectly() internal {
        (address[3] memory targets, bytes[3] memory payloads) = _wiringCalls();
        for (uint256 i = 0; i < 3; i++) {
            (bool ok,) = targets[i].call(payloads[i]);
            require(ok, "wiring call failed");
        }
    }

}
