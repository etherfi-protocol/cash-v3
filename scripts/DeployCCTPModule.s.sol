// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { CCTPModule } from "../src/modules/cctp/CCTPModule.sol";
import { EtherFiDeployerHelper } from "./utils/EtherFiDeployerHelper.sol";

/**
 * @title DeployCCTPModule
 * @notice CREATE3-deploys the immutable CCTPModule on OP mainnet through the on-chain
 *         EtherFiDeployer, so the address is known before broadcast and the enable 3CP can be
 *         authored and reviewed first. Post-deploy wiring (grant CCTP_MODULE_ADMIN_ROLE via the
 *         timelock, configureDefaultModules, configureModulesCanRequestWithdraw,
 *         setAllowedRoutes, setproviderFeeRecipient) ships as 3CP bundles, matching
 *         DeployStargateModule's split.
 * @dev Prod only.
 */
contract DeployCCTPModule is EtherFiDeployerHelper {
    using stdJson for string;

    // OP mainnet: Circle-native USDC + CCTP V2 TokenMessengerV2 (same address on dev and prod)
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;

    string constant SALT = "Prod.CCTP.CCTPModule";
    /// @notice Pinned CREATE3 address of `SALT`, so a salt typo fails before broadcast.
    address constant EXPECTED_MODULE = 0xFEF147ce61614aa787B6E68c24Ff096D13593A9d;

    function run() public {
        require(block.chainid == 10, "This script must be run on Optimism (chain ID 10)");
        require(!isEqualString(getEnv(), "dev"), "dev module is already deployed at 0x7b370f2582C07D042408304D720Bbef5133cA0B2");
        require(_predictAddress(SALT) == EXPECTED_MODULE, "salt does not resolve to the pinned address");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        require(DEPLOYER.isDeployer(vm.addr(deployerPk)), "broadcaster is not an EtherFiDeployer deployer");

        string memory deployments = readDeploymentFile();
        address dataProvider = deployments.readAddress(".addresses.EtherFiDataProvider");

        address[] memory assets = new address[](1);
        assets[0] = USDC;

        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({
            tokenMessenger: TOKEN_MESSENGER,
            maxFeeBps: 200, // Fast-transfer relay-fee ceiling paid to Circle, not an ether.fi fee
            providerFeeBps: 0 // Stargate parity: no ether.fi fee on withdrawals; changeable later via setAssetConfig
        });

        vm.startBroadcast(deployerPk);
        address module = _create3(SALT, type(CCTPModule).creationCode, abi.encode(assets, cfgs, dataProvider));
        vm.stopBroadcast();

        require(module == EXPECTED_MODULE, "module did not land at the pinned address");
        require(module.code.length > 0, "CREATE3 verification failed");
        console.log("CCTPModule:", module);
        console.log("Next: record it at .addresses.CCTPModule in deployments/mainnet/10/deployments.json, then generate the enable 3CP.");
    }
}
