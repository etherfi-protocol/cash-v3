// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console2 } from "forge-std/console2.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TradingSafeWithdrawModule } from "../../src/trading-safe/TradingSafeWithdrawModule.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @notice Post-broadcast verification for `DeployTradingSafeWithdrawModuleDev`, run against the live
 *         chain. Every check `require`s, so a non-zero exit means the dev module is NOT usable.
 * @dev Checks, in order: the manifest address is the deterministic CREATE3 address for the dev salt
 *      (an impl at any other address means something other than this script deployed it); its runtime
 *      bytecode matches a local rebuild against the dev data provider; the immutable data-provider
 *      binding resolves to the dev stack; the module is whitelisted AND default, so every existing dev
 *      TradingSafe has it enabled; and the pause switch actually works — exercised by pranking, not
 *      just read off `hasRole`, since the roles are the means and a working kill switch is the end.
 *      Read-only: it never broadcasts, so the pause/unpause round trip lives only in the fork.
 *
 * Usage:
 *   source .env && forge script scripts/trading-account/VerifyTradingSafeWithdrawModuleDev.s.sol \
 *     --rpc-url $MAINNET_RPC
 */
contract VerifyTradingSafeWithdrawModuleDev is Utils {
    using stdJson for string;

    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;
    string private constant SALT_NAME = "TradingAccount.Dev.v1.TradingSafeWithdrawModule";

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");

        string memory manifest = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/1/trading-account.json"));
        address dataProvider = manifest.readAddress(".EtherFiDataProvider");
        address module = manifest.readAddress(".TradingSafeWithdrawModule");

        require(module == DEPLOYER.getDeterministicAddress(getSalt(SALT_NAME)), "module is not the dev CREATE3 address");
        require(module.code.length > 0, "module not deployed");
        _requireBytecodeMatch(module, address(new TradingSafeWithdrawModule(dataProvider)));

        EtherFiDataProvider provider = EtherFiDataProvider(dataProvider);
        RoleRegistry registry = RoleRegistry(address(provider.roleRegistry()));
        require(address(registry) == manifest.readAddress(".RoleRegistry"), "registry is not the dev manifest registry");
        require(address(TradingSafeWithdrawModule(module).etherFiDataProvider()) == dataProvider, "module bound to wrong data provider");

        require(provider.isWhitelistedModule(module), "module not whitelisted");
        require(provider.isDefaultModule(module), "module not default");
        require(registry.hasRole(registry.PAUSER(), DEV_ADMIN), "dev admin not PAUSER");
        require(registry.hasRole(registry.UNPAUSER(), DEV_ADMIN), "dev admin not UNPAUSER");
        require(registry.owner() == DEV_ADMIN, "dev admin does not own the dev RoleRegistry");

        _requirePauseSwitchLive(module);

        console2.log("Dev TradingSafeWithdrawModule verified:", module);
    }

    /// @dev The module holds no `address(this)` immutable, so the runtime code of a local rebuild
    ///      against the same data provider must match byte for byte.
    function _requireBytecodeMatch(address deployed, address local) private view {
        require(deployed.code.length == local.code.length, "module bytecode length mismatch");
        require(keccak256(deployed.code) == keccak256(local.code), "module runtime bytecode mismatch");
    }

    /// @dev Both directions of the switch, and the module left unpaused.
    function _requirePauseSwitchLive(address module) private {
        TradingSafeWithdrawModule m = TradingSafeWithdrawModule(module);
        require(!m.paused(), "module is paused");

        vm.prank(DEV_ADMIN);
        m.pause();
        require(m.paused(), "pause did not take effect");

        vm.prank(DEV_ADMIN);
        m.unpause();
        require(!m.paused(), "unpause did not take effect");
    }
}
