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
 *      Env: PRIVATE_KEY (deployer), CASHBACK_DISTRIBUTOR_RELAYER (relayer to authorize),
 *      CASHBACK_DISTRIBUTOR_ETHFI (ETHFI token), CASHBACK_DISTRIBUTOR_SETHFI (sETHFI liquid-
 *      vault share token) -- both immutable on the implementation, so they must be correct at
 *      deploy time; changing them later requires a new implementation and an upgrade -- plus
 *      ENV + chain so readDeploymentFile() resolves the RoleRegistry address.
 *
 *      Post-deploy steps (this script only completes the first):
 *      1. Grant `CASHBACK_DISTRIBUTOR_ROLE` to the relayer (done above).
 *      2. Fund the CashbackDistributor proxy itself with the ETHFI/other tokens that
 *         `award`/`awardBatch`/`awardStaked` pay out -- the contract custodies these funds
 *         directly and pays from its own balance; there is no payout-wallet allowance anymore.
 *      3. If cashback will be settled via `awardStaked`, call `setTeller` (role registry owner)
 *         with the BoringVault-style teller for staking ETHFI into sETHFI.
 */
contract DeployCashbackDistributor is Utils {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address relayer = vm.envAddress("CASHBACK_DISTRIBUTOR_RELAYER");
        address ethfi = vm.envAddress("CASHBACK_DISTRIBUTOR_ETHFI");
        address sEthfi = vm.envAddress("CASHBACK_DISTRIBUTOR_SETHFI");

        string memory deployments = readDeploymentFile();
        address roleRegistry = stdJson.readAddress(deployments, string.concat(".", "addresses", ".", "RoleRegistry"));

        vm.startBroadcast(deployerPrivateKey);

        bytes memory initData = abi.encodeWithSelector(CashbackDistributor.initialize.selector, roleRegistry);
        address impl = address(new CashbackDistributor(ethfi, sEthfi));
        address proxy = address(new UUPSProxy(impl, initData));

        RoleRegistry(roleRegistry).grantRole(CashbackDistributor(proxy).CASHBACK_DISTRIBUTOR_ROLE(), relayer);

        vm.stopBroadcast();

        console2.log("CashbackDistributor impl :", impl);
        console2.log("CashbackDistributor proxy:", proxy);
        console2.log("Relayer granted CASHBACK_DISTRIBUTOR_ROLE:", relayer);
    }
}
