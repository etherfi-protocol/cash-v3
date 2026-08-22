// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { UUPSProxy } from "../src/UUPSProxy.sol";
import { CashbackDistributor } from "../src/cashback-distributor/CashbackDistributor.sol";
import { RoleRegistry } from "../src/role-registry/RoleRegistry.sol";
import { ChainConfig, Utils } from "./utils/Utils.sol";

/**
 * @notice Deploys CashbackDistributor behind a UUPS proxy and grants the backend payout
 *         relayer CASHBACK_DISTRIBUTOR_ROLE.
 * @dev grantRole must be sent by the RoleRegistry owner. On networks where the owner is a
 *      multisig/governance (prod), drop the grantRole line and grant via scripts/gnosis-txs/.
 *      Env: PRIVATE_KEY (deployer), CASHBACK_DISTRIBUTOR_RELAYER (relayer to authorize), plus
 *      ENV + chain so readDeploymentFile() resolves the RoleRegistry address.
 *
 *      Post-deploy steps (this script only completes the first):
 *      1. Grant `CASHBACK_DISTRIBUTOR_ROLE` to the relayer (done above).
 *      2. Fund the payout wallet with the ETHFI and sETHFI that `award`/`awardBatch` will pay out.
 *      3. From the payout wallet, `approve` the deployed CashbackDistributor proxy to spend ETHFI.
 *      4. From the payout wallet, `approve` the deployed CashbackDistributor proxy to spend sETHFI.
 *      `award`/`awardBatch` pull funds via `transferFrom(msg.sender, ...)`; without steps 3-4 the
 *      first claim for a token reverts `ERC20InsufficientAllowance` and burns the retry cap.
 */
contract DeployCashbackDistributor is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address relayer = vm.envAddress("CASHBACK_DISTRIBUTOR_RELAYER");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));

        vm.startBroadcast(deployerPrivateKey);

        bytes memory initData = abi.encodeWithSelector(CashbackDistributor.initialize.selector, roleRegistry);
        address impl = address(new CashbackDistributor());
        address proxy = address(new UUPSProxy(impl, initData));

        RoleRegistry(roleRegistry).grantRole(CashbackDistributor(proxy).CASHBACK_DISTRIBUTOR_ROLE(), relayer);

        vm.stopBroadcast();

        console2.log("CashbackDistributor impl :", impl);
        console2.log("CashbackDistributor proxy:", proxy);
        console2.log("Relayer granted CASHBACK_DISTRIBUTOR_ROLE:", relayer);
    }
}
