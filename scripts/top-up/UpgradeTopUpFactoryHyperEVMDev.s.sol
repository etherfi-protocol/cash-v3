// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { CREATE3 } from "solady/utils/CREATE3.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { TopUpConfigHelper } from "../utils/TopUpConfigHelper.sol";

/**
 * @title UpgradeTopUpFactoryHyperEVMDev
 * @notice Brings dev's HyperEVM TopUpSourceFactory up to the current TopUpFactory, which is the
 *         blocker for testing any HyperEVM top-up on dev.
 *
 *         Dev's proxy (`0x5c361f94…Bcf0`) still points at `0x6DE91D12…6aE0`, an implementation that
 *         predates the chain-scoped interface: `getTokenConfig(address,uint256)` and
 *         `setTokenConfig(address[],uint256[],TokenConfig[])` revert on it, while the single-dest
 *         `getTokenConfig(address)` still works. Prod HyperEVM was migrated long ago
 *         (`0x0681a8bB…b80C`), which is why only dev is broken.
 *
 *         **The upgrade alone is not enough.** The old implementation stored configs as
 *         `tokenConfig[token]`; the current one stores `tokenChainConfig[token][destChainId]`.
 *         Nothing reads the old slot after the upgrade, so every dev HyperEVM token config —
 *         USDC, wHYPE, beHYPE and USDT0, across both destination chains — must be re-set from the
 *         fixture in the same run, or dev HyperEVM top-ups break for every asset rather than just
 *         the new one. That is what the prod migration script did too.
 *
 *         Dev-only by construction: it broadcasts from an EOA and asserts that EOA is the
 *         RoleRegistry's upgrader and owner. Prod is gated differently (3CP / timelock) and its
 *         factory is already current, so there is nothing here to run against it.
 *
 * @dev Separately fixed in the dev fixture, and worth knowing when reviewing this: dev's `usdt`
 *      entry for destination 10 had `oftAdapter` set to the USD₮0 *token* address
 *      (`0xB8CE59FC…625EBB`) rather than the OFT (`0x904861a2…37E98`). The token does not implement
 *      `token()`/`peers()`, so the bridge leg would have failed at send time even once the config
 *      applied. Prod always had the correct OFT.
 *
 * Usage (drop --broadcast to simulate):
 *   source .env && ENV=dev forge script scripts/top-up/UpgradeTopUpFactoryHyperEVMDev.s.sol:UpgradeTopUpFactoryHyperEVMDev \
 *     --rpc-url $HYPEREVM_RPC --broadcast -vvvv
 */
contract UpgradeTopUpFactoryHyperEVMDev is TopUpConfigHelper {
    /// @dev Permissioned CREATE3 deployer — same address on every cash chain, live on HyperEVM.
    address internal constant ETHERFI_DEPLOYER = 0xFCD957b5913d607BF2222280093421B1e2Af6f30;

    string internal constant DEPLOYER_RECORD_PATH = "/deployments/deployer/etherfi-deployer.json";

    /// @dev Dev-scoped salt. Deliberately distinct from the prod migration's
    ///      "TopupsMigration.Prod.TopUpFactoryHyperEVMImpl" so the two never collide.
    bytes32 internal constant SALT_FACTORY_IMPL = keccak256("TopupsMigration.Dev.TopUpFactoryHyperEVMImpl");

    uint256 internal constant HYPEREVM_CHAIN_ID = 999;

    function run() public {
        require(block.chainid == HYPEREVM_CHAIN_ID, "HyperEVM (999) only");
        require(isEqualString(getEnv(), "dev"), "ENV must be dev -- prod HyperEVM is already current and is not EOA-upgradeable");

        string memory deployments = readTopUpSourceDeployment();
        address proxy = stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory");
        address roleRegistryAddr = stdJson.readAddress(deployments, ".addresses.RoleRegistry");
        IRoleRegistry roleRegistry = IRoleRegistry(roleRegistryAddr);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);

        // Pre-flight: fail before spending gas if this key cannot both deploy and upgrade.
        address recorded = stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), DEPLOYER_RECORD_PATH)), ".EtherFiDeployer");
        require(recorded == ETHERFI_DEPLOYER, "ETHERFI_DEPLOYER does not match deployments/deployer/etherfi-deployer.json");
        require(ETHERFI_DEPLOYER.code.length != 0, "EtherFiDeployer not deployed on HyperEVM");
        require(EtherFiDeployer(ETHERFI_DEPLOYER).isDeployer(broadcaster), "broadcaster is not a registered EtherFiDeployer deployer");
        // Reverts OnlyUpgrader if the key cannot upgrade, which is the check that matters most here.
        roleRegistry.onlyUpgrader(broadcaster);

        console.log("=== Upgrade dev HyperEVM TopUpFactory ===");
        console.log("Proxy:         ", proxy);
        console.log("Current impl:  ", _implementationOf(proxy));
        console.log("Broadcaster:   ", broadcaster);

        address predicted = CREATE3.predictDeterministicAddress(SALT_FACTORY_IMPL, ETHERFI_DEPLOYER);
        console.log("Predicted impl:", predicted);

        vm.startBroadcast(pk);

        address impl = predicted;
        if (predicted.code.length > 0) {
            console.log("  [SKIP] implementation already deployed");
        } else {
            impl = EtherFiDeployer(ETHERFI_DEPLOYER).deploy(SALT_FACTORY_IMPL, type(TopUpFactory).creationCode);
            require(impl == predicted, "CREATE3 address mismatch");
        }
        // TopUpFactory carries immutables, so `type(...).runtimeCode` is unavailable and an exact
        // bytecode equality check is not possible here. CREATE3 already pins the address to this
        // salt + deployer, and only registered deployers can place code there, so the address match
        // above is the real guarantee; this just rules out an empty deploy.
        require(impl.code.length > 0, "implementation has no code");

        if (_implementationOf(proxy) == impl) {
            console.log("  [SKIP] proxy already points at this implementation");
        } else {
            UUPSUpgradeable(proxy).upgradeToAndCall(impl, "");
            console.log("  [OK] proxy upgraded");
        }

        // Storage layout moved from tokenConfig[token] to tokenChainConfig[token][destChainId], so
        // every config has to be written again -- not just the one this project adds.
        topUpFactory = TopUpFactory(payable(proxy));
        _loadAdapters(deployments);
        (address[] memory tokens, uint256[] memory chainIds, TopUpFactory.TokenConfig[] memory configs) = parseAllTokenConfigs();
        require(tokens.length > 0, "fixture produced no token configs -- refusing to leave the factory empty");

        topUpFactory.setTokenConfig(tokens, chainIds, configs);
        console.log("  [OK] re-applied token configs:", tokens.length);

        vm.stopBroadcast();

        require(_implementationOf(proxy) == impl, "proxy implementation did not stick");

        // Read every config back through the NEW chain-scoped getter. This is the assertion that
        // actually proves the upgrade worked, since that getter reverted before it.
        for (uint256 i = 0; i < tokens.length; i++) {
            TopUpFactory.TokenConfig memory actual = topUpFactory.getTokenConfig(tokens[i], chainIds[i]);
            require(actual.bridgeAdapter == configs[i].bridgeAdapter, "bridgeAdapter mismatch after upgrade");
            require(actual.recipientOnDestChain == configs[i].recipientOnDestChain, "recipient mismatch after upgrade");
            require(uint256(actual.maxSlippageInBps) == uint256(configs[i].maxSlippageInBps), "maxSlippage mismatch after upgrade");
            require(keccak256(actual.additionalData) == keccak256(configs[i].additionalData), "additionalData mismatch after upgrade");
        }

        console.log("  [OK] all configs read back through getTokenConfig(token, chainId)");
        console.log("New impl:      ", impl);
    }

    function _implementationOf(address proxy) internal view returns (address) {
        // EIP-1967 implementation slot
        return address(uint160(uint256(vm.load(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))));
    }
}
