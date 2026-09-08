// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { CCTPModule } from "../../src/modules/cctp/CCTPModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/**
 * @title EnableCCTPModuleOptimism
 * @notice Generates and fork-simulates the 3CP bundles that switch on the CREATE3-deployed
 *         CCTPModule on OP mainnet. Three Safe transactions at consecutive nonces:
 *
 *           step 1  tl.schedule(RoleRegistry.grantRole(CCTP_MODULE_ADMIN_ROLE, Safe)), 8h
 *           step 2  tl.execute(same payload), >= 8h after step 1 lands
 *           step 3  MultiSend batch, needs the role from step 2 for its last two calls:
 *                     dataProvider.configureDefaultModules([module], [true])
 *                     cashModule.configureModulesCanRequestWithdraw([module], [true])
 *                     module.setAllowedRoutes(USDC, [ETH, Arbitrum, Base, HyperEVM], all true)
 *                     module.setproviderFeeRecipient(ops wallet)
 *
 *         Run against an OP fork with no broadcast. If the module is not deployed yet the
 *         simulation deploys it locally through the EtherFiDeployer with the exact args of
 *         DeployCCTPModule so the post-state checks are meaningful; the real deploy is still a
 *         precondition for signing.
 * @dev Prod only. ENV must be mainnet (the default).
 */
contract EnableCCTPModuleOptimism is EtherFiDeployerHelper, GnosisHelpers {
    using stdJson for string;

    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant ETHERFI_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    uint256 internal constant TIMELOCK_DELAY = 8 hours;
    bytes32 internal constant TL_PREDECESSOR = bytes32(0);
    /// @dev Non-zero so the operation id can never collide with a zero-salted payload.
    bytes32 internal constant TL_SALT = keccak256("CCTP.GrantModuleAdminRole.OP");

    // Must match DeployCCTPModule exactly; the simulation re-deploys with these when needed.
    string internal constant SALT = "Prod.CCTP.CCTPModule";
    address internal constant MODULE = 0xFEF147ce61614aa787B6E68c24Ff096D13593A9d;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    uint256 internal constant MAX_FEE_BPS = 200;
    uint256 internal constant PROVIDER_FEE_BPS = 0;

    // Circle CCTP v2 destination domains for the chains the app withdraws to. 2 is OP itself and is
    // never a destination. Avalanche (1) is left closed and used as the negative check.
    uint32 internal constant DOMAIN_ETHEREUM = 0;
    uint32 internal constant DOMAIN_ARBITRUM = 3;
    uint32 internal constant DOMAIN_BASE = 6;
    uint32 internal constant DOMAIN_HYPEREVM = 19;
    uint32 internal constant DOMAIN_AVALANCHE = 1;

    /// @dev providerFeeBps is 0 at launch; the recipient (ops wallet Safe) is set so a later fee change cannot brick requests.
    address internal constant PROVIDER_FEE_RECIPIENT = 0x86fBaEB3D6b5247F420590D303a6ffC9cd523790;

    string internal constant OUT_DIR = "./output/";

    EtherFiDataProvider internal dataProvider;
    ICashModule internal cashModule;
    RoleRegistry internal roleRegistry;
    EtherFiTimelock internal tl = EtherFiTimelock(payable(ETHERFI_TIMELOCK));
    CCTPModule internal module = CCTPModule(MODULE);

    function run() public {
        require(block.chainid == 10, "run on Optimism (chain id 10)");
        require(isEqualString(getEnv(), "mainnet"), "prod only: ENV must be mainnet");
        require(_predictAddress(SALT) == MODULE, "salt does not resolve to the pinned module address");

        string memory deployments = readDeploymentFile();
        dataProvider = EtherFiDataProvider(deployments.readAddress(".addresses.EtherFiDataProvider"));
        cashModule = ICashModule(deployments.readAddress(".addresses.CashModule"));
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));

        bytes32 role = keccak256("CCTP_MODULE_ADMIN_ROLE");
        bytes memory grantPayload = abi.encodeCall(RoleRegistry.grantRole, (role, SAFE));
        bytes32 opId = tl.hashOperation(address(roleRegistry), 0, grantPayload, TL_PREDECESSOR, TL_SALT);

        _checkPreconditions(role, opId);
        _ensureModuleForSimulation(role);

        string memory step1 = _writeBundle("optimism-cctp-step1-schedule", _single(ETHERFI_TIMELOCK,
            abi.encodeCall(tl.schedule, (address(roleRegistry), 0, grantPayload, TL_PREDECESSOR, TL_SALT, TIMELOCK_DELAY))));
        string memory step2 = _writeBundle("optimism-cctp-step2-execute", _single(ETHERFI_TIMELOCK,
            abi.encodeCall(tl.execute, (address(roleRegistry), 0, grantPayload, TL_PREDECESSOR, TL_SALT))));
        string memory step3 = _writeBundle("optimism-cctp-step3-enable-module", _enableBatch());

        _simulate(step1, step2, step3, role, opId);

        console.log("");
        console.log("CCTP_MODULE_ADMIN_ROLE:");
        console.logBytes32(role);
        console.log("timelock salt:");
        console.logBytes32(TL_SALT);
        console.log("timelock operation id:");
        console.logBytes32(opId);
        console.log("module:", MODULE);
        console.log("Safe nonce at authoring:", _safeNonce());
    }

    function _checkPreconditions(bytes32 role, bytes32 opId) internal view {
        require(roleRegistry.owner() == ETHERFI_TIMELOCK, "RoleRegistry owner is not the timelock");
        require(tl.getMinDelay() == TIMELOCK_DELAY, "timelock minDelay != 8h");
        require(tl.hasRole(tl.PROPOSER_ROLE(), SAFE), "Safe is not a timelock proposer");
        require(tl.hasRole(tl.EXECUTOR_ROLE(), SAFE), "Safe is not a timelock executor");
        require(!tl.isOperation(opId), "operation already scheduled");
        require(!roleRegistry.hasRole(role, SAFE), "Safe already holds CCTP_MODULE_ADMIN_ROLE");
        require(roleRegistry.hasRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), SAFE), "Safe lacks DATA_PROVIDER_ADMIN_ROLE");
        require(roleRegistry.hasRole(keccak256("CASH_MODULE_CONTROLLER_ROLE"), SAFE), "Safe lacks CASH_MODULE_CONTROLLER_ROLE");
        require(!dataProvider.isWhitelistedModule(MODULE), "module already whitelisted");
        require(!_canRequestWithdraw(MODULE), "module already allowed to request withdrawals");
        require(USDC.code.length > 0 && TOKEN_MESSENGER.code.length > 0, "USDC or TokenMessengerV2 missing on this fork");
    }

    /// @dev Deploys the module on the fork when the real deploy has not happened yet, then checks its config either way.
    function _ensureModuleForSimulation(bytes32 role) internal {
        if (MODULE.code.length == 0) {
            console.log("WARNING: module not deployed on-chain yet; deploying on the fork only");
            address[] memory assets = new address[](1);
            assets[0] = USDC;
            CCTPModule.AssetConfig[] memory cfgs = new CCTPModule.AssetConfig[](1);
            cfgs[0] = CCTPModule.AssetConfig({ tokenMessenger: TOKEN_MESSENGER, maxFeeBps: MAX_FEE_BPS, providerFeeBps: PROVIDER_FEE_BPS });
            address deployer = DEPLOYER.getDeployers()[0];
            vm.prank(deployer);
            address deployed = DEPLOYER.deploy(getSalt(SALT), abi.encodePacked(type(CCTPModule).creationCode, abi.encode(assets, cfgs, address(dataProvider))));
            require(deployed == MODULE, "fork deploy did not land at the pinned address");
        }

        CCTPModule.AssetConfig memory cfg = module.getAssetConfig(USDC);
        require(cfg.tokenMessenger == TOKEN_MESSENGER, "module USDC tokenMessenger mismatch");
        require(cfg.maxFeeBps == MAX_FEE_BPS, "module USDC maxFeeBps mismatch");
        require(cfg.providerFeeBps == PROVIDER_FEE_BPS, "module USDC providerFeeBps mismatch");
        require(module.CCTP_MODULE_ADMIN_ROLE() == role, "module admin role constant mismatch");
        require(module.getproviderFeeRecipient() == address(0), "fee recipient already set");
        uint32[] memory domains = _domains();
        for (uint256 i = 0; i < domains.length; i++) {
            require(!module.isRouteAllowed(USDC, domains[i]), "route already allowed");
        }
    }

    function _single(address to, bytes memory data) internal view returns (string memory) {
        return string.concat(_getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE)), _getGnosisTransaction(addressToHex(to), iToHex(data), "0", true));
    }

    function _enableBatch() internal view returns (string memory txs) {
        address[] memory modules = new address[](1);
        modules[0] = MODULE;
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        uint32[] memory domains = _domains();
        bool[] memory allowed = new bool[](domains.length);
        for (uint256 i = 0; i < allowed.length; i++) {
            allowed[i] = true;
        }

        txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(dataProvider)), iToHex(abi.encodeCall(EtherFiDataProvider.configureDefaultModules, (modules, yes))), "0", false));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(cashModule)), iToHex(abi.encodeCall(ICashModule.configureModulesCanRequestWithdraw, (modules, yes))), "0", false));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(MODULE), iToHex(abi.encodeCall(CCTPModule.setAllowedRoutes, (USDC, domains, allowed))), "0", false));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(MODULE), iToHex(abi.encodeCall(CCTPModule.setproviderFeeRecipient, (PROVIDER_FEE_RECIPIENT))), "0", true));
    }

    function _writeBundle(string memory name, string memory txs) internal returns (string memory path) {
        path = string.concat(OUT_DIR, name, ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    function _simulate(string memory step1, string memory step2, string memory step3, bytes32 role, bytes32 opId) internal {
        address ownerBefore = roleRegistry.owner();
        uint256 whitelistedBefore = dataProvider.getWhitelistedModules().length;

        // Step 3 must fail before the role lands: setAllowedRoutes is admin-gated.
        vm.prank(SAFE);
        (bool early,) = MODULE.call(abi.encodeCall(CCTPModule.setproviderFeeRecipient, (PROVIDER_FEE_RECIPIENT)));
        require(!early, "SIM FAILED: Safe could configure the module without the role");

        console.log("=== step 1: schedule ===");
        executeGnosisTransactionBundle(step1);
        require(tl.isOperationPending(opId), "SIM FAILED: operation not pending");
        require(!roleRegistry.hasRole(role, SAFE), "SIM FAILED: role granted at schedule time");

        vm.prank(SAFE);
        (bool tooSoon,) = ETHERFI_TIMELOCK.call(vm.parseJsonBytes(vm.readFile(step2), ".transactions[0].data"));
        require(!tooSoon, "SIM FAILED: execute succeeded before the delay");

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        require(tl.isOperationReady(opId), "SIM FAILED: operation not ready after 8h");

        console.log("=== step 2: execute ===");
        executeGnosisTransactionBundle(step2);
        require(tl.isOperationDone(opId), "SIM FAILED: operation not done");
        require(roleRegistry.hasRole(role, SAFE), "SIM FAILED: Safe did not receive CCTP_MODULE_ADMIN_ROLE");
        require(roleRegistry.owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");

        console.log("=== step 3: enable module ===");
        executeGnosisTransactionBundle(step3);
        require(dataProvider.isWhitelistedModule(MODULE), "SIM FAILED: module not whitelisted");
        require(dataProvider.isDefaultModule(MODULE), "SIM FAILED: module not default");
        require(dataProvider.getWhitelistedModules().length == whitelistedBefore + 1, "SIM FAILED: whitelist changed by more than one");
        require(_canRequestWithdraw(MODULE), "SIM FAILED: module cannot request withdrawals");
        uint32[] memory domains = _domains();
        for (uint256 i = 0; i < domains.length; i++) {
            require(module.isRouteAllowed(USDC, domains[i]), "SIM FAILED: route not allowed");
        }
        require(!module.isRouteAllowed(USDC, DOMAIN_AVALANCHE), "SIM FAILED: Avalanche route unexpectedly allowed");
        require(!module.isRouteAllowed(USDC, 2), "SIM FAILED: OP self route unexpectedly allowed");
        require(module.getproviderFeeRecipient() == PROVIDER_FEE_RECIPIENT, "SIM FAILED: fee recipient not set");
        require(module.getproviderFee(USDC, 1_000_000e6) == 0, "SIM FAILED: provider fee is not zero");
        (address feeToken, uint256 providerFee, uint256 cctpMaxFee) = module.getBridgeFee(USDC, 1_000e6, module.FINALITY_CONFIRMED());
        require(feeToken == USDC && providerFee == 0 && cctpMaxFee == 1_000e6 * MAX_FEE_BPS / 10_000, "SIM FAILED: unexpected bridge fee quote");

        console.log("[OK] all three bundles simulated; module whitelisted, default, can request withdrawals, 4 USDC routes open");
    }

    function _domains() internal pure returns (uint32[] memory) {
        uint32[] memory domains = new uint32[](4);
        domains[0] = DOMAIN_ETHEREUM;
        domains[1] = DOMAIN_ARBITRUM;
        domains[2] = DOMAIN_BASE;
        domains[3] = DOMAIN_HYPEREVM;
        return domains;
    }

    function _canRequestWithdraw(address m) internal view returns (bool) {
        address[] memory list = cashModule.getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == m) {
                return true;
            }
        }
        return false;
    }

    function _safeNonce() internal view returns (uint256 nonce) {
        (bool ok, bytes memory ret) = SAFE.staticcall(abi.encodeWithSignature("nonce()"));
        require(ok, "Safe nonce() failed");
        nonce = abi.decode(ret, (uint256));
    }
}
