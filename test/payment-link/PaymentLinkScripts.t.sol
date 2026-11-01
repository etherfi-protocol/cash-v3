// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";
import { Vm, VmSafe } from "forge-std/Vm.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { EnablePaymentLinkModuleOP3CP } from "../../scripts/gnosis-txs/EnablePaymentLinkModuleOP3CP.s.sol";
import { DeployPaymentLinkModule } from "../../scripts/payment-link/DeployPaymentLinkModule.s.sol";
import { VerifyPaymentLinkBytecode } from "../../scripts/payment-link/VerifyPaymentLinkBytecode.s.sol";
import { PaymentLinkConfig } from "../../scripts/payment-link/PaymentLinkConfig.sol";
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
    address internal txTo;
    bytes internal txInput;
    bool internal txSuccess;

    /// @dev The proxy deploy transaction the provenance check sees, in place of `cast` over RPC.
    ///      A zero `to` with empty input stands for "no tx hash provided".
    constructor(address to, bytes memory input, bool success) {
        txTo = to;
        txInput = input;
        txSuccess = success;
    }

    function _env() internal pure override returns (string memory) {
        return "mainnet";
    }

    function _proxyDeployTx() internal view override returns (bytes32) {
        return txTo == address(0) && txInput.length == 0 ? bytes32(0) : keccak256("test-proxy-deploy-tx");
    }

    function _fetchTx(bytes32) internal view override returns (DeployTx memory) {
        return DeployTx({ to: txTo, input: txInput, success: txSuccess });
    }

    /// @dev Runs only the preconditions (the gate before any bundle is written).
    function checkPreconditions() external {
        _load();
        _checkPreconditions();
    }
}

/// @dev Runs the shared PLM-04 check against any stack and any pair of addresses.
contract BuiltCodeHarness is PaymentLinkConfig {
    function check(string memory env, address impl, address proxy) external {
        _requireBuiltCode(_stack(env), impl, proxy);
    }
}

/// @dev Exposes the real `cast`-over-ffi transaction reader.
contract ProvenanceProbe is PaymentLinkConfig {
    function fetch(bytes32 txHash) external returns (address to, bytes memory input, bool success) {
        DeployTx memory t = _fetchTx(txHash);
        return (t.to, t.input, t.success);
    }
}

/// @dev Codex pass 2 attack: a custom constructor that leaves exactly the expected proxy runtime,
///      impl slot, RoleRegistry slot and Initializable state, but also seeds a Funded link with no
///      liability behind it. Runtime and slot checks cannot see it; only deployment provenance can.
contract PoisonedProxy {
    constructor(address impl, address registry, address seededSigner, address token) {
        bytes32 linkSlot = keccak256(abi.encode(seededSigner, uint256(0x72f6ddc7d992479425dc8c9c22860bd7f83946c3315c4ff3de0873cbf7571b00)));
        assembly {
            sstore(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc, impl)
            sstore(0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500, registry)
            sstore(0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00, 1)
            sstore(linkSlot, 0xdead) // safe
            sstore(add(linkSlot, 1), token)
            sstore(add(linkSlot, 2), 100000000) // 100 USDC
            sstore(add(linkSlot, 3), shl(16, 2)) // feeBps 0, status Funded
        }
        bytes memory runtime = type(UUPSProxy).runtimeCode;
        assembly {
            return(add(runtime, 32), mload(runtime))
        }
    }
}

/// @dev PLM-04 attack shape: an ERC-1967 proxy with the genuine impl in its slot, so every slot
///      and getter check passes, plus one extra function that only a bytecode check can see.
contract ProxyWithBackdoor is UUPSProxy {
    constructor(address impl) UUPSProxy(impl, "") { }

    receive() external payable { }

    function sweep(address token, address to) external {
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
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
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @dev The calldata the deploy script sent to `EtherFiDeployer.deploy` for the prod proxy.
    bytes internal proxyDeployCall;

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
        _deployProd();
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
        Enable3CPHarness gen = _new3CP();
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

        // 5. Re-running is refused: mainnet never reuses code at the pinned addresses (PLM-04),
        //    and the 3CP refuses to rebuild an applied bundle.
        DeployHarness redeploy = new DeployHarness("mainnet", deployerPk);
        vm.expectRevert(bytes("mainnet: code already exists at the pinned impl address - refusing to reuse it"));
        redeploy.run();
        Enable3CPHarness again = _new3CP();
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
        assertTrue(PaymentLinkModule(DEV_PROXY).isTokenAllowed(USDC), "dev deploy allows USDC");

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
        _deployProd();
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

    function test_deploy_mainnetRefusesExistingCodeAtPinnedAddresses() public {
        // Code at the impl address only (for example an earlier deploy from other code).
        uint256 snap = vm.snapshotState();
        vm.etch(PROD_IMPL, hex"00");
        DeployHarness script = new DeployHarness("mainnet", deployerPk);
        vm.expectRevert(bytes("mainnet: code already exists at the pinned impl address - refusing to reuse it"));
        script.run();
        vm.revertToState(snap);

        // Code at the proxy address only.
        vm.etch(PROD_PROXY, hex"00");
        script = new DeployHarness("mainnet", deployerPk);
        vm.expectRevert(bytes("mainnet: code already exists at the pinned proxy address - refusing to reuse it"));
        script.run();
    }

    /// @dev PLM-04: a proxy that keeps the right slots and getters but adds a function must not
    ///      get an enable bundle.
    function test_enable3CP_rejectsProxyWhoseCodeDiffers() public {
        _deployProd();
        Enable3CPHarness gen = _new3CP();
        gen.checkPreconditions(); // control: the genuine proxy passes

        vm.etch(PROD_PROXY, address(new ProxyWithBackdoor(PROD_IMPL)).code);
        // The swap is invisible to the slot and getter checks...
        assertEq(address(uint160(uint256(vm.load(PROD_PROXY, EIP1967_IMPL_SLOT)))), PROD_IMPL);
        assertEq(address(uint160(uint256(vm.load(PROD_PROXY, UPGRADEABLE_PROXY_STORAGE_SLOT)))), address(prodRoleRegistry));
        assertEq(address(PaymentLinkModule(PROD_PROXY).cashModule()), address(prodCashModule));
        (uint16 feeBps, address feeReceiver) = PaymentLinkModule(PROD_PROXY).getFee();
        assertEq(feeBps, 0);
        assertEq(feeReceiver, address(0));

        // ...but not to the exact proxy bytecode comparison.
        gen = _new3CP();
        vm.expectRevert();
        gen.checkPreconditions();

        // The standalone bytecode verifier rejects it the same way.
        BytecodeHarness verifier = new BytecodeHarness("mainnet");
        vm.expectRevert();
        verifier.run();
    }

    /// @dev Codex: the right runtime code is not enough; a proxy that never ran its initializer
    ///      (or an impl whose initializers are not locked) could be initialized by anyone later.
    function test_enable3CP_rejectsUninitialisedProxyOrUnlockedImpl() public {
        _deployProd();
        Enable3CPHarness gen = _new3CP();
        gen.checkPreconditions(); // control

        uint256 snap = vm.snapshotState();
        vm.store(PROD_PROXY, INITIALIZABLE_STORAGE_SLOT, bytes32(0));
        gen = _new3CP();
        vm.expectRevert(bytes("proxy not initialised exactly once"));
        gen.checkPreconditions();
        vm.revertToState(snap);

        // Version 1 but flagged mid-initialization is rejected too (the whole slot is compared).
        vm.store(PROD_PROXY, INITIALIZABLE_STORAGE_SLOT, bytes32(uint256(1) | (uint256(1) << 64)));
        gen = _new3CP();
        vm.expectRevert(bytes("proxy not initialised exactly once"));
        gen.checkPreconditions();
        vm.revertToState(snap);

        vm.store(PROD_IMPL, INITIALIZABLE_STORAGE_SLOT, bytes32(0));
        gen = _new3CP();
        vm.expectRevert(bytes("impl initializers not disabled"));
        gen.checkPreconditions();
    }

    /// @dev Codex: an impl built against another stack must fail the prod check by its
    ///      immutables, whatever the embedded-address code comparison would conclude.
    function test_builtCode_rejectsImplBoundToAnotherStack() public {
        vm.startPrank(devRoleRegistry.owner());
        devRoleRegistry.grantRole(keccak256("ADMIN_TIMELOCK_ROLE"), deployerAddr);
        vm.stopPrank();
        new DeployHarness("dev", deployerPk).run();

        BuiltCodeHarness checker = new BuiltCodeHarness();
        checker.check("dev", DEV_IMPL, DEV_PROXY); // control: right stack

        vm.expectRevert(bytes("PaymentLinkModule impl: etherFiDataProvider immutable is not this stack's"));
        checker.check("mainnet", DEV_IMPL, DEV_PROXY);
    }

    function test_enable3CP_refusesWithoutDeployment() public {
        Enable3CPHarness gen = _new3CP();
        vm.expectRevert(bytes("PaymentLinkModule proxy has no code - deploy it first"));
        gen.run();
    }

    function test_deploy_refusesUnregisteredDeployer() public {
        (, uint256 strangerPk) = makeAddrAndKey("notADeployer");
        DeployHarness script = new DeployHarness("mainnet", strangerPk);
        vm.expectRevert(bytes("broadcaster is not an EtherFiDeployer deployer"));
        script.run();
    }

    // ---- deployment provenance (Codex pass 2) ----

    function test_enable3CP_rejectsDeployTxThatIsNotTheExpectedCall() public {
        _deployProd();
        _new3CP().checkPreconditions(); // control: the call the deploy script actually sent

        Enable3CPHarness gen = new Enable3CPHarness(address(0), "", false);
        vm.expectRevert(bytes("proxy deploy tx hash not provided (set PAYMENT_LINK_PROXY_DEPLOY_TX)"));
        gen.checkPreconditions();

        gen = new Enable3CPHarness(address(DEPLOYER), proxyDeployCall, false);
        vm.expectRevert(bytes("proxy deploy tx did not succeed"));
        gen.checkPreconditions();

        gen = new Enable3CPHarness(makeAddr("someBatcher"), proxyDeployCall, true);
        vm.expectRevert(bytes("proxy deploy tx was not a direct call to the EtherFiDeployer"));
        gen.checkPreconditions();

        bytes memory otherInit = abi.encodeCall(PaymentLinkModule.initialize, (address(prodRoleRegistry), 30, PROD_SAFE));
        bytes memory otherCall = abi.encodeCall(EtherFiDeployer.deploy, (keccak256("Prod.PaymentLink.PaymentLinkModuleProxy"), abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(PROD_IMPL, otherInit))));
        gen = new Enable3CPHarness(address(DEPLOYER), otherCall, true);
        vm.expectRevert(bytes("proxy deploy tx is not the expected EtherFiDeployer.deploy call - proxy storage unverified"));
        gen.checkPreconditions();
    }

    /// @dev Codex pass 2 Blocking: the right runtime, slots and Initializable state with a seeded
    ///      Funded link passes every runtime check; the provenance check rejects it.
    function test_enable3CP_rejectsPoisonedConstructorState() public {
        address attacker = makeAddr("seededLinkSigner");
        deployCodeTo("PaymentLinkModule.sol:PaymentLinkModule", abi.encode(address(prodDataProvider), address(prodCashModule)), PROD_IMPL);
        bytes memory poisonedArgs = abi.encode(PROD_IMPL, address(prodRoleRegistry), attacker, USDC);
        deployCodeTo("PaymentLinkScripts.t.sol:PoisonedProxy", poisonedArgs, PROD_PROXY);

        // Invisible to the runtime, slot and initialisation checks...
        new BuiltCodeHarness().check("mainnet", PROD_IMPL, PROD_PROXY);
        assertEq(uint8(PaymentLinkModule(PROD_PROXY).getLink(attacker).status), 2, "seeded link is Funded");
        assertEq(PaymentLinkModule(PROD_PROXY).getLiabilities(USDC), 0, "with no liability behind it");

        // ...but its deploy tx is not the expected call, so no enable bundle is written.
        bytes memory poisonedCall = abi.encodeCall(EtherFiDeployer.deploy, (keccak256("Prod.PaymentLink.PaymentLinkModuleProxy"), abi.encodePacked(type(PoisonedProxy).creationCode, poisonedArgs)));
        Enable3CPHarness gen = new Enable3CPHarness(address(DEPLOYER), poisonedCall, true);
        vm.expectRevert(bytes("proxy deploy tx is not the expected EtherFiDeployer.deploy call - proxy storage unverified"));
        gen.checkPreconditions();
    }

    /// @dev Codex pass 2: an impl whose embedded `__self` equals the local reference's address
    ///      byte-matches the reference, so only the direct `proxiableUUID()` call catches it.
    function test_builtCode_rejectsImplWhoseSelfIsNotItsAddress() public {
        _deployProd();
        BuiltCodeHarness checker = new BuiltCodeHarness();
        address localRef = vm.computeCreateAddress(address(checker), vm.getNonce(address(checker)));

        bytes memory code = PROD_IMPL.code;
        bytes20 from = bytes20(PROD_IMPL);
        bytes20 to = bytes20(localRef);
        uint256 patched;
        for (uint256 i = 0; i + 20 <= code.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < 20 && hit; j++) {
                hit = code[i + j] == from[j];
            }
            if (hit) {
                for (uint256 j = 0; j < 20; j++) {
                    code[i + j] = to[j];
                }
                patched++;
                i += 19;
            }
        }
        assertGt(patched, 0, "impl embeds its own address");
        vm.etch(PROD_IMPL, code);

        vm.expectRevert(bytes("PaymentLinkModule impl: proxiableUUID reverts when called directly - embedded __self is not the impl address"));
        checker.check("mainnet", PROD_IMPL, PROD_PROXY);
    }

    /// @dev The real reader (`cast` over ffi) on a real EtherFiDeployer.deploy transaction on
    ///      Optimism (the wspyx price-feed deploy recorded in broadcast/DeployWspyxPaxgProdFeeds.s.sol).
    function test_provenance_readsARealDeployerTransaction() public {
        (address to, bytes memory input, bool success) = new ProvenanceProbe().fetch(0x4c0685a2f0eca4c8da73e2de9fac18691be90cd7a1bf543aaa7fd1b19a3b8bfe);
        assertEq(to, address(DEPLOYER));
        assertTrue(success);
        assertEq(bytes4(input), EtherFiDeployer.deploy.selector);
        assertGt(input.length, 68);
    }

    // ---- helpers ----

    /// @dev Runs the real prod deploy and keeps the calldata it sent for the proxy, which the
    ///      3CP's provenance check is then given in place of an on-chain transaction.
    function _deployProd() internal {
        vm.startStateDiffRecording();
        new DeployHarness("mainnet", deployerPk).run();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        bytes32 proxySalt = keccak256("Prod.PaymentLink.PaymentLinkModuleProxy");
        delete proxyDeployCall;
        for (uint256 i = 0; i < accesses.length; i++) {
            if (accesses[i].account != address(DEPLOYER) || accesses[i].kind != VmSafe.AccountAccessKind.Call) continue;
            bytes memory data = accesses[i].data;
            if (data.length < 36 || bytes4(data) != EtherFiDeployer.deploy.selector) continue;
            bytes32 salt;
            assembly {
                salt := mload(add(data, 36))
            }
            if (salt == proxySalt) proxyDeployCall = data;
        }
        require(proxyDeployCall.length > 0, "prod proxy deploy call not captured");
    }

    function _new3CP() internal returns (Enable3CPHarness) {
        return new Enable3CPHarness(address(DEPLOYER), proxyDeployCall, true);
    }

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
        assertEq(targets.length, 4);
        assertEq(targets[0], address(prodDataProvider));
        assertEq(targets[1], address(prodCashModule));
        assertEq(targets[2], PROD_PROXY);
        assertEq(targets[3], PROD_PROXY);
        for (uint256 i = 0; i < 4; i++) {
            assertEq(values[i], 0);
        }
        address[] memory modules = new address[](1);
        modules[0] = PROD_PROXY;
        bool[] memory enable = new bool[](1);
        enable[0] = true;
        assertEq(payloads[0], abi.encodeCall(EtherFiDataProvider.configureModules, (modules, enable)));
        assertEq(payloads[1], abi.encodeCall(ICashModule.configureModulesCanRequestWithdraw, (modules, enable)));
        assertEq(payloads[2], abi.encodeCall(PaymentLinkModule.setFee, (30, PROD_SAFE)));
        assertEq(payloads[3], abi.encodeCall(PaymentLinkModule.setTokenAllowed, (USDC, true)));
    }

    function _assertNoDeploys(Vm.Log[] memory logs) internal pure {
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(DEPLOYER), "re-run deployed a contract");
        }
    }
}
