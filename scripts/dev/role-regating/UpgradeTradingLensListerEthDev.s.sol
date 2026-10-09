// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { RoleRegistry } from "../../../src/role-registry/RoleRegistry.sol";
import { TradingLens } from "../../../src/trading-safe/TradingLens.sol";
import { EtherFiDeployer } from "../../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../../utils/Utils.sol";

/**
 * @notice Upgrades the Ethereum dev TradingLens to the impl with TRADING_LENS_TOKEN_LISTER_ROLE and
 *         grants that role to the dev backend wallet, which held TRADING_LENS_ADMIN_ROLE until the
 *         2026-10-02 dev re-gating revoked it.
 *
 *         Idempotent - the deploy, upgrade and grant are skipped when already in the target state. With
 *         PRIVATE_KEY unset the run broadcasts as DEV_ADMIN, which only works against a fork with
 *         impersonation.
 *
 * Usage (fork):
 *   anvil --fork-url $MAINNET_RPC --auto-impersonate
 *   forge script scripts/dev/role-regating/UpgradeTradingLensListerEthDev.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * Usage (broadcast):
 *   source .env && forge script scripts/dev/role-regating/UpgradeTradingLensListerEthDev.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract UpgradeTradingLensListerEthDev is Utils {
    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    address private constant ROLE_REGISTRY = 0x823a20D7e0586423dD2f99724479C74d8B65794E;
    address private constant PRICE_PROVIDER = 0x18120B84dF313BB486B0713A07e2401A56F22Df1;
    address private constant TRADING_LENS = 0xC6d33e123164e540431165C22dC9D9f09cFb00e9;
    address private constant TOKEN_LISTER = 0xd45390905Ad84d8330B8e004aC4297c904Fa6ED3;

    string private constant SALT = "CCTPRegate.Dev.v1.TradingEth.TradingLensImpl";

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(DEPLOYER.isDeployer(DEV_ADMIN), "dev admin is not an EtherFiDeployer");

        RoleRegistry registry = RoleRegistry(ROLE_REGISTRY);
        require(registry.owner() == DEV_ADMIN, "dev admin does not own the trading RoleRegistry");
        require(address(TradingLens(TRADING_LENS).roleRegistry()) == ROLE_REGISTRY, "lens points at another registry");
        require(address(TradingLens(TRADING_LENS).priceProvider()) == PRICE_PROVIDER, "lens price provider changed");

        address[] memory tokensBefore = TradingLens(TRADING_LENS).getSupportedTokens();

        _startBroadcast();

        address newImpl = _deployImpl();
        if (_currentImpl(TRADING_LENS) != newImpl) {
            UUPSUpgradeable(TRADING_LENS).upgradeToAndCall(newImpl, "");
            console2.log("  [OK] TradingLens upgraded");
        } else {
            console2.log("  [SKIP] TradingLens already on target impl");
        }

        bytes32 listerRole = TradingLens(TRADING_LENS).TRADING_LENS_TOKEN_LISTER_ROLE();
        if (!registry.hasRole(listerRole, TOKEN_LISTER)) {
            registry.grantRole(listerRole, TOKEN_LISTER);
            console2.log("  [OK] granted TRADING_LENS_TOKEN_LISTER_ROLE to", TOKEN_LISTER);
        } else {
            console2.log("  [SKIP] token lister already holds the role");
        }

        vm.stopBroadcast();

        require(_currentImpl(TRADING_LENS) == newImpl, "upgrade did not stick");
        require(listerRole == keccak256("TRADING_LENS_TOKEN_LISTER_ROLE"), "unexpected role hash");
        require(registry.hasRole(listerRole, TOKEN_LISTER), "token lister lacks the role");
        require(!registry.hasRole(registry.ADMIN_ROLE(), TOKEN_LISTER), "token lister unexpectedly holds ADMIN_ROLE");
        require(address(TradingLens(TRADING_LENS).priceProvider()) == PRICE_PROVIDER, "price provider changed");

        address[] memory tokensAfter = TradingLens(TRADING_LENS).getSupportedTokens();
        require(keccak256(abi.encode(tokensAfter)) == keccak256(abi.encode(tokensBefore)), "supported tokens changed across the upgrade");

        require(registry.owner() == DEV_ADMIN, "CRITICAL: trading RoleRegistry owner changed!");
        console2.log("  [OK] supported tokens preserved:", tokensAfter.length);
    }

    function _deployImpl() internal returns (address deployed) {
        bytes32 salt = getSalt(SALT);
        deployed = DEPLOYER.getDeterministicAddress(salt);
        if (deployed.code.length > 0) {
            console2.log("  [SKIP] TradingLensImpl already deployed at", deployed);
            return deployed;
        }
        address result = DEPLOYER.deploy(salt, abi.encodePacked(type(TradingLens).creationCode, abi.encode(PRICE_PROVIDER)));
        require(result == deployed, "TradingLensImpl deployed off the predicted address");
        console2.log("  [OK] deployed TradingLensImpl at", deployed);
    }

    function _currentImpl(address proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
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
