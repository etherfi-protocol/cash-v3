// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { EnablePaymentLinkModuleOP3CP } from "../../scripts/gnosis-txs/EnablePaymentLinkModuleOP3CP.s.sol";
import { DeployPaymentLinkModule } from "../../scripts/payment-link/DeployPaymentLinkModule.s.sol";
import { VerifyPaymentLinkBytecode } from "../../scripts/payment-link/VerifyPaymentLinkBytecode.s.sol";
import { VerifyPaymentLinkModule } from "../../scripts/payment-link/VerifyPaymentLinkModule.s.sol";

// ---- Harnesses: the real scripts with their environment inputs pinned per instance ----
// (overriding the virtual hooks instead of vm.setEnv, which would leak into parallel suites)

contract DeployHarness is DeployPaymentLinkModule {
    string internal env_;
    uint256 internal key_;

    constructor(string memory env__, uint256 key__) {
        env_ = env__;
        key_ = key__;
    }

    function _env() internal view override returns (string memory) {
        return env_;
    }

    function _deployerKey() internal view override returns (uint256) {
        return key_;
    }
}

contract VerifyHarness is VerifyPaymentLinkModule {
    string internal env_;
    bool internal deployOnly_;
    address internal devFeeReceiver_;

    constructor(string memory env__, bool deployOnly__, address devFeeReceiver__) {
        env_ = env__;
        deployOnly_ = deployOnly__;
        devFeeReceiver_ = devFeeReceiver__;
    }

    function _env() internal view override returns (string memory) {
        return env_;
    }

    function _deployOnly() internal view override returns (bool) {
        return deployOnly_;
    }

    function _devFeeReceiver(Stack memory) internal view override returns (address) {
        return devFeeReceiver_;
    }
}

contract BytecodeHarness is VerifyPaymentLinkBytecode {
    string internal env_;

    constructor(string memory env__) {
        env_ = env__;
    }

    function _env() internal view override returns (string memory) {
        return env_;
    }
}

contract Enable3CPHarness is EnablePaymentLinkModuleOP3CP {
    function _env() internal pure override returns (string memory) {
        return "mainnet";
    }
}

/**
 * @title PaymentLinkScriptsTest
 * @notice Runs the PAY-1171 scripts end to end on an Optimism mainnet fork, without broadcasting
 *         anything: the prod deploy, the deploy-only verification, the bytecode check, the
 *         timelocked enable 3CP with its own simulation, the post-enable verification, the dev
 *         deploy with direct wiring to the DEV stack only, and re-runs that must change nothing.
 *         The deployer is a test key registered on the fork's EtherFiDeployer by pranking its owner.
 * @dev Needs an Optimism RPC: TEST_RPC (as in CI), falling back to the fixtures' public RPC.
 *      Run with: TEST_CHAIN=10 TEST_RPC=<optimism rpc> forge test --match-path test/payment-link/PaymentLinkScripts.t.sol
 */
contract PaymentLinkScriptsTest is Test {
    using stdJson for string;

    EtherFiDeployer internal constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address internal constant PROD_PROXY = 0x7402a988651bAF0558642647e0D7366D939d35c4;
    address internal constant PROD_IMPL = 0x4d3B98947f10c36FE495110186fF854aB0F5593f;
    address internal constant DEV_PROXY = 0x1bfCca1f03252D6734dCaB45F37AE3f81f6E0781;
    address internal constant DEV_IMPL = 0x0393014ce03Fe8F0EfeF0817D7c439474ff748dD;
    address internal constant PROD_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    address internal deployerAddr;
    uint256 internal deployerPk;

    EtherFiDataProvider internal prodDataProvider;
    ICashModule internal prodCashModule;
    RoleRegistry internal prodRoleRegistry;
    EtherFiDataProvider internal devDataProvider;
    ICashModule internal devCashModule;
    RoleRegistry internal devRoleRegistry;

    function setUp() public {
        string memory rpc = vm.envOr("TEST_RPC", string("https://mainnet.optimism.io"));
        vm.createSelectFork(rpc);
        require(block.chainid == 10, "PaymentLinkScriptsTest needs an Optimism RPC");

        (deployerAddr, deployerPk) = makeAddrAndKey("paymentLinkTestDeployer");
        address[] memory deployers = new address[](1);
        deployers[0] = deployerAddr;
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        vm.prank(DEPLOYER.owner());
        DEPLOYER.configureDeployers(deployers, yes);

        string memory prod = vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/10/deployments.json"));
        prodDataProvider = EtherFiDataProvider(prod.readAddress(".addresses.EtherFiDataProvider"));
        prodCashModule = ICashModule(prod.readAddress(".addresses.CashModule"));
        prodRoleRegistry = RoleRegistry(prod.readAddress(".addresses.RoleRegistry"));
        string memory dev = vm.readFile(string.concat(vm.projectRoot(), "/deployments/dev/10/deployments.json"));
        devDataProvider = EtherFiDataProvider(dev.readAddress(".addresses.EtherFiDataProvider"));
        devCashModule = ICashModule(dev.readAddress(".addresses.CashModule"));
        devRoleRegistry = RoleRegistry(dev.readAddress(".addresses.RoleRegistry"));
    }

    function test_pinnedAddresses_matchSaltsAndDeployer() public view {
        assertEq(CREATE3.predictDeterministicAddress(keccak256("Prod.PaymentLink.PaymentLinkModuleProxy"), address(DEPLOYER)), PROD_PROXY);
        assertEq(CREATE3.predictDeterministicAddress(keccak256("Prod.PaymentLink.PaymentLinkModuleImpl"), address(DEPLOYER)), PROD_IMPL);
        assertEq(CREATE3.predictDeterministicAddress(keccak256("Dev.PaymentLink.PaymentLinkModuleProxy"), address(DEPLOYER)), DEV_PROXY);
        assertEq(CREATE3.predictDeterministicAddress(keccak256("Dev.PaymentLink.PaymentLinkModuleImpl"), address(DEPLOYER)), DEV_IMPL);
        assertEq(DEPLOYER.getDeterministicAddress(keccak256("Prod.PaymentLink.PaymentLinkModuleProxy")), PROD_PROXY);
        assertEq(DEPLOYER.getDeterministicAddress(keccak256("Dev.PaymentLink.PaymentLinkModuleProxy")), DEV_PROXY);
    }

    function test_prod_deployVerifyEnable3CP_endToEnd() public {
        // 1. Deploy (unprivileged CREATE3 only on prod).
        new DeployHarness("mainnet", deployerPk).run();
        assertGt(PROD_PROXY.code.length, 0);
        assertEq(address(uint160(uint256(vm.load(PROD_PROXY, EIP1967_IMPL_SLOT)))), PROD_IMPL);
        assertFalse(prodDataProvider.isWhitelistedModule(PROD_PROXY), "prod deploy must not wire anything");
        (uint16 feeBps, address feeReceiver) = PaymentLinkModule(PROD_PROXY).getFee();
        assertEq(feeBps, 0);
        assertEq(feeReceiver, address(0));

        // 2. Verification between deploy and the 3CP, plus the bytecode proof.
        new VerifyHarness("mainnet", true, address(0)).run();
        new BytecodeHarness("mainnet").run();

        // 3. The enable 3CP: writes both bundles and simulates schedule -> 8h -> execute.
        Enable3CPHarness gen = new Enable3CPHarness();
        gen.run();
        _assertBundle(gen.step1Path(), bytes4(keccak256("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)")));
        _assertBundle(gen.step2Path(), bytes4(keccak256("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)")));

        // 4. The simulated end state passes the full verification.
        new VerifyHarness("mainnet", false, address(0)).run();
        assertTrue(prodDataProvider.isWhitelistedModule(PROD_PROXY));
        assertFalse(prodDataProvider.isDefaultModule(PROD_PROXY));
        (feeBps, feeReceiver) = PaymentLinkModule(PROD_PROXY).getFee();
        assertEq(feeBps, 30);
        assertEq(feeReceiver, PROD_SAFE);

        // 5. Re-running is safe: the deploy changes nothing and the 3CP refuses to rebuild.
        vm.recordLogs();
        new DeployHarness("mainnet", deployerPk).run();
        _assertNoDeploys(vm.getRecordedLogs());
        Enable3CPHarness again = new Enable3CPHarness();
        vm.expectRevert(bytes("module fee already configured - enable already done?"));
        again.run();

        vm.removeFile(gen.step1Path());
        vm.removeFile(gen.step2Path());
    }

    function test_dev_deployWiresDevStackOnly_andIsIdempotent() public {
        // The dev broadcaster holds every role on the dev RoleRegistry; mirror that for the test key.
        vm.startPrank(devRoleRegistry.owner());
        devRoleRegistry.grantRole(keccak256("ADMIN_TIMELOCK_ROLE"), deployerAddr);
        vm.stopPrank();

        new DeployHarness("dev", deployerPk).run();

        assertTrue(devDataProvider.isWhitelistedModule(DEV_PROXY));
        assertFalse(devDataProvider.isDefaultModule(DEV_PROXY));
        (uint16 feeBps, address feeReceiver) = PaymentLinkModule(DEV_PROXY).getFee();
        assertEq(feeBps, 30);
        assertEq(feeReceiver, deployerAddr);
        assertEq(address(PaymentLinkModule(DEV_PROXY).cashModule()), address(devCashModule));

        // Production cannot see the dev instance.
        assertFalse(prodDataProvider.isWhitelistedModule(DEV_PROXY));
        address[] memory prodRequesters = prodCashModule.getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < prodRequesters.length; i++) {
            assertTrue(prodRequesters[i] != DEV_PROXY, "dev module on the prod CashModule requester list");
        }

        // The verifier passes (including its own prod-isolation checks) and the bytecode matches.
        new VerifyHarness("dev", false, deployerAddr).run();
        new BytecodeHarness("dev").run();

        // A re-run deploys nothing and re-wires nothing.
        vm.recordLogs();
        new DeployHarness("dev", deployerPk).run();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertNoDeploys(logs);
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != DEV_PROXY && logs[i].emitter != address(devDataProvider), "re-run emitted state changes");
        }
    }

    function test_verify_detectsHijackedProxy() public {
        new DeployHarness("mainnet", deployerPk).run();
        VerifyHarness verifier = new VerifyHarness("mainnet", true, address(0));
        verifier.run();

        uint256 snap = vm.snapshotState();
        vm.store(PROD_PROXY, EIP1967_IMPL_SLOT, bytes32(uint256(uint160(makeAddr("evilImpl")))));
        vm.expectRevert(bytes("impl address mismatch - possible hijack"));
        verifier.run();
        vm.revertToState(snap);

        vm.store(PROD_PROXY, UPGRADEABLE_PROXY_STORAGE_SLOT, bytes32(uint256(uint160(makeAddr("evilRegistry")))));
        vm.expectRevert(bytes("roleRegistry mismatch - possible hijack"));
        verifier.run();
    }

    function test_enable3CP_refusesWithoutDeployment() public {
        Enable3CPHarness gen = new Enable3CPHarness();
        vm.expectRevert(bytes("PaymentLinkModule proxy has no code - deploy it first"));
        gen.run();
    }

    function test_deploy_refusesUnregisteredDeployer() public {
        (, uint256 strangerPk) = makeAddrAndKey("notADeployer");
        DeployHarness script = new DeployHarness("mainnet", strangerPk);
        vm.expectRevert(bytes("broadcaster is not an EtherFiDeployer deployer"));
        script.run();
    }

    // ---- helpers ----

    /// @dev A bundle is one Safe transaction to the operating timelock carrying the 3-call batch.
    function _assertBundle(string memory path, bytes4 selector) internal view {
        string memory json = vm.readFile(path);
        assertEq(json.readAddress(".safeAddress"), PROD_SAFE);
        assertEq(json.readString(".chainId"), "10");
        assertEq(json.readAddress(".transactions[0].to"), 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849);
        assertFalse(vm.keyExistsJson(json, ".transactions[1]"), "bundle must hold exactly one transaction");

        bytes memory data = json.readBytes(".transactions[0].data");
        assertEq(bytes4(data), selector);
        bytes memory args = new bytes(data.length - 4);
        for (uint256 i = 0; i < args.length; i++) {
            args[i] = data[i + 4];
        }
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = abi.decode(args, (address[], uint256[], bytes[]));
        assertEq(targets.length, 3);
        assertEq(targets[0], address(prodDataProvider));
        assertEq(targets[1], address(prodCashModule));
        assertEq(targets[2], PROD_PROXY);
        for (uint256 i = 0; i < 3; i++) {
            assertEq(values[i], 0);
        }
        address[] memory modules = new address[](1);
        modules[0] = PROD_PROXY;
        bool[] memory enable = new bool[](1);
        enable[0] = true;
        assertEq(payloads[0], abi.encodeCall(EtherFiDataProvider.configureModules, (modules, enable)));
        assertEq(payloads[1], abi.encodeCall(ICashModule.configureModulesCanRequestWithdraw, (modules, enable)));
        assertEq(payloads[2], abi.encodeCall(PaymentLinkModule.setFee, (30, PROD_SAFE)));
    }

    function _assertNoDeploys(Vm.Log[] memory logs) internal pure {
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(DEPLOYER), "re-run deployed a contract");
        }
    }
}
