// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

/**
 * @title DeployStockUnwrapper
 * @notice Deploys the Ethereum-side StockUnwrapper (CREATE3 impl + CREATE3 UUPS proxy with
 *         atomic init) through the on-chain EtherFiDeployer, and grants
 *         STOCK_UNWRAPPER_ADMIN_ROLE. Run AFTER DeployStockWithdrawModule on OP, so
 *         SRC_MODULE is known.
 *
 *         Two-actor flow, selected by ENV:
 *         - ENV=dev:      the broadcaster owns the RoleRegistry — the role grant is
 *                         broadcast directly.
 *         - ENV=mainnet:  the broadcaster only performs the unprivileged CREATE3 deploys;
 *                         the role grant is written as a Gnosis transaction bundle to
 *                         output/StockUnwrapper-<chainid>.json for the prod Safe
 *                         (RoleRegistry owner) to execute.
 *
 *         Adapters are configured post-deploy by the unwrapper admin via `configureAdapters`
 *         as OFTAdapters get listed.
 *
 * The RoleRegistry is read from deployments/{ENV}/1/trading-account.json. The OP
 * StockWithdrawModule address is PREDICTED from its CREATE3 salt (the EtherFiDeployer lives
 * at the same address on every chain), so it needs no env/config plumbing. The LayerZero
 * endpoint and OP EID are chain constants.
 *
 * Env: PRIVATE_KEY (must be a registered EtherFiDeployer deployer), ENV (dev|mainnet),
 *      UNWRAPPER_ADMIN (address receiving STOCK_UNWRAPPER_ADMIN_ROLE)
 *
 * Run with --verify. After broadcast (and bundle execution on prod), run
 * VerifyStockUnwrapper.s.sol against the live chain.
 */
contract DeployStockUnwrapper is EtherFiDeployerHelper, GnosisHelpers {
    using stdJson for string;

    string internal constant SALT_IMPL = "StockWithdraw.StockUnwrapperImpl";
    string internal constant SALT_PROXY = "StockWithdraw.StockUnwrapperProxy";
    string internal constant SALT_SRC_MODULE_PROXY = "StockWithdraw.StockWithdrawModuleProxy";

    /// @notice LayerZero V2 endpoint on Ethereum mainnet.
    address internal constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    /// @notice OP mainnet endpoint ID.
    uint32 internal constant SRC_EID = 30111;

    RoleRegistry internal roleRegistry;
    address internal unwrapperAdmin;
    address internal impl;
    address internal proxy;

    function run() public {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        string memory tradingAccount = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/trading-account.json"));
        roleRegistry = RoleRegistry(tradingAccount.readAddress(".RoleRegistry"));
        unwrapperAdmin = vm.envAddress("UNWRAPPER_ADMIN");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        require(DEPLOYER.isDeployer(vm.addr(deployerPk)), "broadcaster is not an EtherFiDeployer deployer");

        address ownerBefore = roleRegistry.owner();
        bool isDev = isEqualString(getEnv(), "dev");

        vm.startBroadcast(deployerPk);
        _deploy();
        if (isDev) {
            (bool ok,) = address(roleRegistry).call(_grantRoleData());
            require(ok, "grantRole failed");
        }
        vm.stopBroadcast();

        if (!isDev) _writeGnosisBundle();

        // Post-operation hook: the timelock/registry owner must be unchanged.
        require(roleRegistry.owner() == ownerBefore, "CRITICAL: role registry owner changed!");

        console.log("StockUnwrapper impl:", impl);
        console.log("StockUnwrapper proxy:", proxy);
    }

    /// @dev CREATE3 deploys: impl + UUPS proxy with atomic init. Adapters start empty and
    ///      are configured post-deploy by the unwrapper admin.
    function _deploy() internal {
        impl = _create3(SALT_IMPL, type(StockUnwrapper).creationCode, "");

        // The OP module proxy address is deterministic from its salt — same EtherFiDeployer
        // address on every chain — so it can be derived here without cross-chain plumbing.
        address srcModule = _predictAddress(SALT_SRC_MODULE_PROXY);

        bytes memory initData = abi.encodeWithSelector(
            StockUnwrapper.initialize.selector,
            address(roleRegistry),
            LZ_ENDPOINT,
            SRC_EID,
            srcModule,
            new address[](0), // adapters — configured post-deploy as OFTAdapters list
            new bool[](0)
        );
        proxy = _create3(SALT_PROXY, type(UUPSProxy).creationCode, abi.encode(impl, initData));
    }

    /// @dev The single privileged wiring call, identical between dev and the prod bundle.
    function _grantRoleData() internal view returns (bytes memory) {
        return abi.encodeWithSignature("grantRole(bytes32,address)", StockUnwrapper(proxy).STOCK_UNWRAPPER_ADMIN_ROLE(), unwrapperAdmin);
    }

    /// @dev Prod: the role grant goes to the RoleRegistry owner (the prod Safe) as a Gnosis
    ///      transaction bundle.
    function _writeGnosisBundle() internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(roleRegistry.owner()));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(roleRegistry)), iToHex(_grantRoleData()), "0", true));

        string memory path = string.concat("./output/StockUnwrapper-", vm.toString(block.chainid), ".json");
        vm.writeFile(path, txs);
        console.log("Gnosis wiring bundle written to:", path);
    }
}
