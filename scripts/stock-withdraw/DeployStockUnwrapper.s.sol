// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { StockWithdrawConfig } from "./StockWithdrawConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

/**
 * @title DeployStockUnwrapper
 * @notice Deploys the Ethereum-side StockUnwrapper (CREATE3 impl + CREATE3 UUPS proxy with
 *         atomic init) through the on-chain EtherFiDeployer, and grants
 *         STOCK_UNWRAPPER_ADMIN_ROLE.
 *
 *         The unwrapper initialises with the FULL config from `StockWithdrawConfig`: the
 *         OFTAdapter allowlist, and the trusted OP StockWithdrawModule PREDICTED from its
 *         CREATE3 salt (the EtherFiDeployer lives at the same address on every chain), so no
 *         cross-chain address plumbing is needed.
 *
 *         Two-actor flow, selected by ENV:
 *         - ENV=dev:      the broadcaster owns the RoleRegistry — the role grant is
 *                         broadcast directly.
 *         - ENV=mainnet:  the broadcaster only performs the unprivileged CREATE3 deploys;
 *                         the role grant is written as a Gnosis transaction bundle to
 *                         output/StockUnwrapper-<chainid>.json for the prod Safe to execute.
 *
 * The RoleRegistry is read from deployments/{ENV}/1/deployments.json; everything else comes
 * from StockWithdrawConfig.
 *
 * Env: PRIVATE_KEY (must be a registered EtherFiDeployer deployer), ENV (dev|mainnet)
 *
 * STOCK_UNWRAPPER_ADMIN_ROLE goes to the broadcaster on dev, and to the prod Safe on
 * mainnet.
 *
 * Run with --verify. After broadcast (and bundle execution on prod), run
 * VerifyStockUnwrapper.s.sol against the live chain.
 */
contract DeployStockUnwrapper is StockWithdrawConfig, GnosisHelpers {
    using stdJson for string;

    RoleRegistry internal roleRegistry;
    address internal unwrapperAdmin;
    address internal impl;
    address internal proxy;

    function run() public {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        string memory deployments = readDeploymentFile();
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPk);
        require(DEPLOYER.isDeployer(deployerAddress), "broadcaster is not an EtherFiDeployer deployer");

        address ownerBefore = roleRegistry.owner();
        unwrapperAdmin = _adminFor(deployerAddress);
        bool isDev = _isDev();

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

    /// @dev CREATE3 deploys: impl + UUPS proxy with atomic init carrying the adapter
    ///      allowlist and the predicted OP module as the trusted compose sender.
    function _deploy() internal {
        impl = _create3(_unwrapperImplSalt(), type(StockUnwrapper).creationCode, "");

        (address[] memory adapters, bool[] memory registered) = _adapters();

        bytes memory initData = abi.encodeWithSelector(
            StockUnwrapper.initialize.selector,
            address(roleRegistry),
            LZ_ENDPOINT_ETHEREUM,
            OP_EID,
            _predictAddress(_moduleProxySalt()),
            adapters,
            registered
        );
        proxy = _create3(_unwrapperProxySalt(), type(UUPSProxy).creationCode, abi.encode(impl, initData));
    }

    /// @dev The single privileged wiring call, identical between dev and the prod bundle.
    function _grantRoleData() internal view returns (bytes memory) {
        return abi.encodeWithSignature("grantRole(bytes32,address)", StockUnwrapper(proxy).STOCK_UNWRAPPER_ADMIN_ROLE(), unwrapperAdmin);
    }

    /// @dev Prod: the role grant goes to the prod Safe as a Gnosis transaction bundle.
    function _writeGnosisBundle() internal {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(roleRegistry)), iToHex(_grantRoleData()), "0", true));

        string memory path = string.concat("./output/StockUnwrapper-", vm.toString(block.chainid), ".json");
        vm.writeFile(path, txs);
        console.log("Gnosis wiring bundle written to:", path);
    }
}
