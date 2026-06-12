// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { Utils } from "../utils/Utils.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";

/**
 * @title DeployEtherFiDeployer
 * @notice Bootstraps the protocol's own CREATE3 deployer on a chain via the canonical
 *         CreateX factory, so the EtherFiDeployer itself lands at the SAME address on
 *         every chain. After this one-time bootstrap, all protocol contracts deploy
 *         through OUR deployer — no further dependency on public factories.
 *
 *         Front-run protection: the salt's first 20 bytes are the broadcaster address.
 *         CreateX hashes such salts together with msg.sender ("permissioned deploy
 *         protection"), so nobody else can ever occupy our address on any chain — even
 *         ones we haven't deployed to yet. Byte 21 is 0x00 (cross-chain redeploy
 *         protection OFF) so the derived address is chain-independent. Because this is
 *         CREATE3, constructor args don't affect the address either.
 *
 *   source .env && ENV=dev forge script scripts/trading-account/DeployEtherFiDeployer.s.sol --rpc-url ethereum --broadcast -vvv --verify
 */
contract DeployEtherFiDeployer is Utils {
    /// @dev Free-entropy tail of the salt. Bump only to intentionally derive a NEW
    ///      cross-chain address family (e.g. a v2 deployer).
    bytes32 constant SALT = keccak256("EtherFiDeployer");

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);
        address owner = broadcaster;

        address[] memory defaultDeployers = new address[](1);
        defaultDeployers[0] = owner;

        vm.startBroadcast(pk);
        deployWithCreate3(
            abi.encodePacked(type(EtherFiDeployer).creationCode, abi.encode(owner, defaultDeployers)),
            SALT
        );
        vm.stopBroadcast();
    }
}
