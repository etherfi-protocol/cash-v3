// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { StockWithdrawConfig } from "./StockWithdrawConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";

/**
 * @title DeployStockWithdrawModule
 * @notice Deploys the OP-side StockWithdrawModule (CREATE3 impl + CREATE3 UUPS proxy with
 *         atomic init) through the on-chain EtherFiDeployer, then wires it up as a DEFAULT
 *         module on the EtherFiDataProvider and as a withdraw-requester on the CashModule,
 *         and grants STOCK_WITHDRAW_MODULE_ADMIN_ROLE.
 *
 *         The module initialises with the FULL config from `StockWithdrawConfig`: the
 *         supported ShadowOFTs and the Ethereum route pointing at the StockUnwrapper's
 *         PREDICTED CREATE3 address (the EtherFiDeployer lives at the same address on every
 *         chain, so the mainnet address is derivable before that deploy runs).
 *
 *         Two-actor flow, selected by ENV:
 *         - ENV=dev:      the broadcaster holds the admin roles (dev admin owns the
 *                         RoleRegistry), so deploys AND wiring are broadcast directly.
 *         - ENV=mainnet:  the broadcaster only performs the unprivileged CREATE3 deploys;
 *                         every privileged call is written as a Gnosis transaction bundle to
 *                         output/StockWithdrawModule-<chainid>.json for the prod Safe to
 *                         execute.
 *
 * Rollout order:
 *   1. OP:  this script — run with --verify (prod: then execute the Gnosis bundle).
 *   2. ETH: DeployStockUnwrapper — run with --verify (prod: then execute its bundle).
 *   3. Further tokens/adapters/routes are added later via the admin setters.
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
contract DeployStockWithdrawModule is StockWithdrawConfig, GnosisHelpers {
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

        if (!isDev) _writeGnosisBundle();

        console.log("StockWithdrawModule impl:", impl);
        console.log("StockWithdrawModule proxy:", proxy);
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

        bytes memory initData = abi.encodeWithSelector(
            StockWithdrawModule.initialize.selector,
            address(roleRegistry),
            COMPOSE_GAS_LIMIT,
            iTokens,
            supported,
            dstEids,
            unwrappers
        );
        proxy = _create3(_moduleProxySalt(), type(UUPSProxy).creationCode, abi.encode(impl, initData));
    }

    /// @dev The three privileged wiring calls, identical between the dev direct path and the
    ///      prod Gnosis bundle.
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

    /// @dev Prod: the wiring goes to the prod Safe as a Gnosis transaction bundle.
    function _writeGnosisBundle() internal {
        (address[3] memory targets, bytes[3] memory payloads) = _wiringCalls();

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        for (uint256 i = 0; i < 3; i++) {
            txs = string.concat(txs, _getGnosisTransaction(addressToHex(targets[i]), iToHex(payloads[i]), "0", i == 2));
        }

        string memory path = string.concat("./output/StockWithdrawModule-", vm.toString(block.chainid), ".json");
        vm.writeFile(path, txs);
        console.log("Gnosis wiring bundle written to:", path);
    }
}
