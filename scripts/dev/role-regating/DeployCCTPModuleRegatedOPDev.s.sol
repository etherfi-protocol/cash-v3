// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";

import { RoleRegistry } from "../../../src/role-registry/RoleRegistry.sol";
import { EtherFiDataProvider } from "../../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../../src/interfaces/ICashModule.sol";
import { CCTPModule } from "../../../src/modules/cctp/CCTPModule.sol";
import { EtherFiDeployer } from "../../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../../utils/Utils.sol";

/**
 * @notice Deploys the re-gated CCTPModule (setters on ADMIN_TIMELOCK_ROLE) on OP dev and enables it
 *         alongside the old one, copying the old module's live config:
 *           USDC: TokenMessengerV2, maxFeeBps 200, providerFeeBps 50
 *           routes: USDC -> Ethereum (0) and Base (6)
 *           provider fee recipient: DEV_ADMIN
 *
 *         CCTPModule is not upgradeable, so this is a new module. The old one stays enabled until
 *         cash-be dev points at the new address; retire it and revoke CCTP_MODULE_ADMIN_ROLE after.
 *
 *         Idempotent - every step is skipped when already in the target state. With PRIVATE_KEY unset
 *         the run broadcasts as DEV_ADMIN, which only works against a fork with impersonation.
 *
 * Usage (fork):
 *   anvil --fork-url $OPTIMISM_RPC --auto-impersonate
 *   forge script scripts/dev/role-regating/DeployCCTPModuleRegatedOPDev.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * Usage (broadcast):
 *   source .env && forge script scripts/dev/role-regating/DeployCCTPModuleRegatedOPDev.s.sol \
 *     --rpc-url $OPTIMISM_RPC --broadcast --verify
 */
contract DeployCCTPModuleRegatedOPDev is Utils {
    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    address private constant ROLE_REGISTRY = 0xa322a04d1e2Cb44672473740F9F35B057FA29CFB;
    address private constant DATA_PROVIDER = 0x4a9c44c97BBf6079db37C4769AebE425bBcDD09a;
    address private constant CASH_MODULE = 0xA4F3A3229FDFBfc7A30FEAC42337d931E85Dc969;
    address private constant OLD_CCTP_MODULE = 0x7b370f2582C07D042408304D720Bbef5133cA0B2;

    address private constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address private constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    uint256 private constant MAX_FEE_BPS = 200;
    uint256 private constant PROVIDER_FEE_BPS = 50;
    address private constant PROVIDER_FEE_RECIPIENT = DEV_ADMIN;
    uint32 private constant DOMAIN_ETHEREUM = 0;
    uint32 private constant DOMAIN_BASE = 6;

    string private constant SALT = "CCTPRegate.Dev.v1.OP.CCTPModule";

    function run() external {
        require(block.chainid == 10, "must run on Optimism");
        require(DEPLOYER.isDeployer(DEV_ADMIN), "dev admin is not an EtherFiDeployer");

        RoleRegistry registry = RoleRegistry(ROLE_REGISTRY);
        require(registry.owner() == DEV_ADMIN, "dev admin does not own the OP dev RoleRegistry");
        require(registry.hasRole(registry.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN), "dev admin lacks ADMIN_TIMELOCK_ROLE");
        require(EtherFiDataProvider(DATA_PROVIDER).getCashModule() == CASH_MODULE, "data provider points at another cash module");

        _startBroadcast();

        CCTPModule module = _deployModule();
        _enableModule(address(module));
        _configureModule(module);

        vm.stopBroadcast();

        _verify(module);
    }

    function _deployModule() internal returns (CCTPModule) {
        console2.log("=== Deploying re-gated CCTPModule ===");
        bytes32 salt = getSalt(SALT);
        address predicted = DEPLOYER.getDeterministicAddress(salt);
        if (predicted.code.length > 0) {
            console2.log("  [SKIP] CCTPModule already deployed at", predicted);
            return CCTPModule(predicted);
        }

        address[] memory assets = new address[](1);
        assets[0] = USDC;
        CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
        cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: TOKEN_MESSENGER, maxFeeBps: MAX_FEE_BPS, providerFeeBps: PROVIDER_FEE_BPS });

        address deployed = DEPLOYER.deploy(salt, abi.encodePacked(type(CCTPModule).creationCode, abi.encode(assets, cfgs, DATA_PROVIDER)));
        require(deployed == predicted, "CCTPModule deployed off the predicted address");
        console2.log("  [OK] deployed CCTPModule at", deployed);
        return CCTPModule(deployed);
    }

    function _enableModule(address module) internal {
        console2.log("=== Enabling CCTPModule ===");
        address[] memory m = new address[](1);
        m[0] = module;
        bool[] memory yes = new bool[](1);
        yes[0] = true;

        if (!EtherFiDataProvider(DATA_PROVIDER).isDefaultModule(module)) {
            EtherFiDataProvider(DATA_PROVIDER).configureDefaultModules(m, yes);
            console2.log("  [OK] marked default module");
        } else {
            console2.log("  [SKIP] already a default module");
        }

        if (!_isWithdrawRequester(module)) {
            ICashModule(CASH_MODULE).configureModulesCanRequestWithdraw(m, yes);
            console2.log("  [OK] granted withdraw-requester status");
        } else {
            console2.log("  [SKIP] already a withdraw requester");
        }
    }

    function _configureModule(CCTPModule module) internal {
        console2.log("=== Configuring CCTPModule ===");
        if (!module.isRouteAllowed(USDC, DOMAIN_ETHEREUM) || !module.isRouteAllowed(USDC, DOMAIN_BASE)) {
            uint32[] memory domains = new uint32[](2);
            domains[0] = DOMAIN_ETHEREUM;
            domains[1] = DOMAIN_BASE;
            bool[] memory allowed = new bool[](2);
            allowed[0] = true;
            allowed[1] = true;
            module.setAllowedRoutes(USDC, domains, allowed);
            console2.log("  [OK] USDC routes to Ethereum and Base allowed");
        } else {
            console2.log("  [SKIP] USDC routes already allowed");
        }

        if (module.getproviderFeeRecipient() != PROVIDER_FEE_RECIPIENT) {
            module.setproviderFeeRecipient(PROVIDER_FEE_RECIPIENT);
            console2.log("  [OK] provider fee recipient set");
        } else {
            console2.log("  [SKIP] provider fee recipient already set");
        }
    }

    function _verify(CCTPModule module) internal view {
        console2.log("=== Verifying ===");
        require(address(module.etherFiDataProvider()) == DATA_PROVIDER, "wrong data provider");

        CCTPModule.AssetConfig memory cfg = module.getAssetConfig(USDC);
        CCTPModule.AssetConfig memory oldCfg = CCTPModule(OLD_CCTP_MODULE).getAssetConfig(USDC);
        require(cfg.tokenMessenger == oldCfg.tokenMessenger && cfg.maxFeeBps == oldCfg.maxFeeBps && cfg.providerFeeBps == oldCfg.providerFeeBps, "USDC config differs from the old module");
        require(module.isRouteAllowed(USDC, DOMAIN_ETHEREUM) && module.isRouteAllowed(USDC, DOMAIN_BASE), "routes not allowed");
        require(module.getproviderFeeRecipient() == CCTPModule(OLD_CCTP_MODULE).getproviderFeeRecipient(), "fee recipient differs from the old module");

        require(EtherFiDataProvider(DATA_PROVIDER).isWhitelistedModule(address(module)), "not whitelisted");
        require(EtherFiDataProvider(DATA_PROVIDER).isDefaultModule(address(module)), "not a default module");
        require(_isWithdrawRequester(address(module)), "not a withdraw requester");

        require(RoleRegistry(ROLE_REGISTRY).owner() == DEV_ADMIN, "CRITICAL: OP dev RoleRegistry owner changed!");
        console2.log("  [OK] new CCTPModule mirrors the old config and is enabled:", address(module));
    }

    function _isWithdrawRequester(address module) internal view returns (bool) {
        address[] memory requesters = ICashModule(CASH_MODULE).getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < requesters.length; ++i) {
            if (requesters[i] == module) return true;
        }
        return false;
    }

    function _startBroadcast() private {
        uint256 privateKey = vm.envOr("PRIVATE_KEY", uint256(0));
        if (privateKey == 0) {
            vm.startBroadcast(DEV_ADMIN);
        } else {
            require(vm.addr(privateKey) == DEV_ADMIN, "PRIVATE_KEY is not the dev admin");
            vm.startBroadcast(privateKey);
        }
    }
}
