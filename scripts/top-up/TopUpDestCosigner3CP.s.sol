// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test, Vm } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { TopUpDest } from "../../src/top-up/TopUpDest.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/**
 * @title TopUpDestCosigner3CP
 * @notice Upgrades the Optimism TopUpDest proxy to the co-signer implementation, then sets the production
 *         co-signer with enforcement off. Two timelocks, two Safes:
 *           Upgrade Safe: schedule, then 2 days later execute, `upgradeToAndCall(impl, "")` (RoleRegistry owner path)
 *           Admin Safe:   schedule, then 8 hours later execute, `configureCosigner(COSIGNER, false)` (ADMIN_TIMELOCK_ROLE)
 *         The configure execute must run after the upgrade execute; before it the function does not exist.
 *
 * Deploy the implementation (CREATE3 through the EtherFiDeployer, registered deployer dev-admin):
 *   forge script scripts/top-up/TopUpDestCosigner3CP.s.sol --sig "deploy()" --rpc-url optimism --account dev-admin --broadcast --verify
 *
 * Write the four bundles to ./output and replay them on a fork (no broadcast). Rehearses the deploy when it has not
 * happened yet:
 *   forge script scripts/top-up/TopUpDestCosigner3CP.s.sol --rpc-url optimism --sender 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E --no-isolate -vvv
 *   (--no-isolate: the replay pranks the Safes, which have code. TOP_UP_LOOKBACK sets the payout scan window in
 *   blocks, default 3000.)
 */
contract TopUpDestCosigner3CP is EtherFiDeployerHelper, GnosisHelpers, Test {
    TopUpDest constant DEST = TopUpDest(payable(0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87));
    address constant CURRENT_IMPL = 0xfd082f251D27e83A62a8Ef9c045EFaeF26B9ce26;
    address constant DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    RoleRegistry constant REGISTRY = RoleRegistry(0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B);

    address constant UPGRADE_SAFE = 0xBAf0E1af05c5ab8Bb709d13e1B6DeDd53b492588;
    address constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    uint256 constant UPGRADE_DELAY = 2 days;
    address constant ADMIN_SAFE = 0x47992A4E7920EE57eb3dD06131C1a086963b240B;
    address constant ADMIN_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    uint256 constant ADMIN_DELAY = 8 hours;

    /// @dev Derived from the AWS KMS key alias/cosigner-production-topup (secp256k1 public key)
    address constant COSIGNER = 0x77784eC7a54CAb497Ad92D74F46e2dB3805bdcb1;
    address constant REGISTERED_DEPLOYER = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    string constant SALT_IMPL = "Prod.TopUpDest.CosignerImpl";
    bytes32 constant SALT_UPGRADE = keccak256("Prod.TopUpDest.cosignerUpgrade");
    bytes32 constant SALT_CONFIGURE = keccak256("Prod.TopUpDest.configureCosigner");
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant TOP_UP_EVENT = keccak256("TopUp(bytes32,address,address,bytes32,uint256,uint256)");
    uint256 constant MAX_SAMPLES = 12;

    struct Payout {
        bytes32 txId;
        bytes32 txHash;
        address user;
        address token;
        uint256 chainId;
        uint256 amount;
    }

    Payout[] samples;
    address[] tokens;
    uint256[] balances;
    uint256[] deposits;
    address worker;
    address impl;
    address[] upgradeTargets;
    bytes[] upgradePayloads;
    address[] configTargets;
    bytes[] configPayloads;

    function deploy() external {
        require(block.chainid == 10, "Optimism only");
        vm.startBroadcast();
        impl = _create3(SALT_IMPL, type(TopUpDest).creationCode, abi.encode(DATA_PROVIDER, WETH));
        vm.stopBroadcast();
        _checkArgs();
        console.log("TopUpDest co-signer implementation:", impl);
    }

    function run() external {
        require(block.chainid == 10, "Optimism only");
        _checkPreconditions();

        impl = _predictAddress(SALT_IMPL);
        if (impl.code.length == 0) {
            vm.prank(REGISTERED_DEPLOYER);
            require(DEPLOYER.deploy(getSalt(SALT_IMPL), abi.encodePacked(type(TopUpDest).creationCode, abi.encode(DATA_PROVIDER, WETH))) == impl, "CREATE3 mismatch");
            console.log("[REHEARSAL] implementation not deployed yet, deployed on the fork at", impl);
        }
        _checkImpl();

        upgradeTargets.push(address(DEST));
        upgradePayloads.push(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", impl, ""));
        configTargets.push(address(DEST));
        configPayloads.push(abi.encodeCall(TopUpDest.configureCosigner, (COSIGNER, false)));

        string memory upSchedule = _write("upgrade-safe-schedule-upgrade", UPGRADE_SAFE, _schedule(upgradeTargets, upgradePayloads, SALT_UPGRADE, UPGRADE_DELAY));
        string memory upExecute = _write("upgrade-safe-execute-upgrade", UPGRADE_SAFE, _execute(upgradeTargets, upgradePayloads, SALT_UPGRADE));
        string memory cfgSchedule = _write("admin-safe-schedule-configure-cosigner", ADMIN_SAFE, _schedule(configTargets, configPayloads, SALT_CONFIGURE, ADMIN_DELAY));
        string memory cfgExecute = _write("admin-safe-execute-configure-cosigner", ADMIN_SAFE, _execute(configTargets, configPayloads, SALT_CONFIGURE));
        console.log("upgrade operation id");
        console.logBytes32(EtherFiTimelock(payable(UPGRADE_TIMELOCK)).hashOperationBatch(upgradeTargets, new uint256[](1), upgradePayloads, bytes32(0), SALT_UPGRADE));
        console.log("configure operation id");
        console.logBytes32(EtherFiTimelock(payable(ADMIN_TIMELOCK)).hashOperationBatch(configTargets, new uint256[](1), configPayloads, bytes32(0), SALT_CONFIGURE));

        _snapshot();
        console.log("fork block", block.number);

        // Both schedules can execute at once; the timelocks do not check the target's code.
        executeGnosisTransactionBundle(upSchedule);
        executeGnosisTransactionBundle(cfgSchedule);

        // Wrong order: the configure execute reverts while the old implementation is live.
        vm.warp(block.timestamp + ADMIN_DELAY + 1);
        vm.prank(ADMIN_SAFE);
        (bool early,) = ADMIN_TIMELOCK.call(_execute(configTargets, configPayloads, SALT_CONFIGURE));
        assertFalse(early, "configure executed before the upgrade");

        vm.warp(block.timestamp + UPGRADE_DELAY);
        executeGnosisTransactionBundle(upExecute);
        assertEq(_implOf(), impl, "implementation slot");
        _assertConfig(address(0), false, 0);
        _assertPreserved();
        _assertPayouts(false);

        vm.recordLogs();
        executeGnosisTransactionBundle(cfgExecute);
        _assertConfiguredEvent(vm.getRecordedLogs());
        _assertConfig(COSIGNER, false, 1);
        _assertPreserved();
        _assertPayouts(true);
        console.log("All checks passed. Samples:", samples.length, "tokens:", tokens.length);
    }

    // ── Checks ─────────────────────────────────────────────────────────────────────

    function _checkPreconditions() internal view {
        require(_implOf() == CURRENT_IMPL, "proxy is not on the pre-co-signer implementation");
        require(address(DEST.roleRegistry()) == address(REGISTRY), "role registry");
        require(REGISTRY.owner() == UPGRADE_TIMELOCK, "RoleRegistry owner is not the upgrade timelock");
        address[] memory adminTimelocks = REGISTRY.roleHolders(uint256(REGISTRY.ADMIN_TIMELOCK_ROLE()));
        require(adminTimelocks.length == 1 && adminTimelocks[0] == ADMIN_TIMELOCK, "ADMIN_TIMELOCK_ROLE holders");
        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY, UPGRADE_SAFE);
        _checkTimelock(ADMIN_TIMELOCK, ADMIN_DELAY, ADMIN_SAFE);
        require(!DEST.paused(), "TopUpDest is paused");
        (bool ok,) = address(DEST).staticcall(abi.encodeCall(TopUpDest.cosignerConfig, ()));
        require(!ok, "cosignerConfig already exists");
    }

    function _checkTimelock(address timelock, uint256 delay, address safe) internal view {
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(tl.getMinDelay() == delay, "timelock delay");
        require(tl.hasRole(tl.PROPOSER_ROLE(), safe) && tl.hasRole(tl.EXECUTOR_ROLE(), safe), "Safe is not proposer and executor");
    }

    /// @dev Same constructor arguments as the live implementation
    function _checkArgs() internal view {
        TopUpDest i = TopUpDest(payable(impl));
        TopUpDest live = TopUpDest(payable(CURRENT_IMPL));
        require(address(i.etherFiDataProvider()) == address(live.etherFiDataProvider()) && address(i.etherFiDataProvider()) == DATA_PROVIDER, "data provider");
        require(address(i.weth()) == address(live.weth()) && address(i.weth()) == WETH, "weth");
    }

    /// @dev Constructor arguments as above, and the same runtime code as a local build. Not usable under broadcast.
    function _checkImpl() internal {
        _checkArgs();
        address local = address(new TopUpDest(DATA_PROVIDER, WETH));
        require(keccak256(_blankSelf(impl.code, impl)) == keccak256(_blankSelf(local.code, local)), "deployed code != local build");
        console.log("implementation codehash");
        console.logBytes32(impl.codehash);
    }

    function _assertConfig(address signer, bool required, uint256 epoch) internal view {
        (address s, bool r, uint256 e) = DEST.cosignerConfig();
        assertEq(s, signer, "cosigner");
        assertEq(r, required, "required");
        assertEq(e, epoch, "epoch");
    }

    function _assertConfiguredEvent(Vm.Log[] memory logs) internal pure {
        bytes32 sig = keccak256("CosignerConfigured(address,bool,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(DEST) && logs[i].topics[0] == sig) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), COSIGNER, "event cosigner");
                (bool required, uint256 epoch) = abi.decode(logs[i].data, (bool, uint256));
                assertFalse(required, "event required");
                assertEq(epoch, 1, "event epoch");
                return;
            }
        }
        revert("CosignerConfigured not emitted");
    }

    /// @dev Completion records, roles, pause, balances and deposits read the same as before the upgrade
    function _assertPreserved() internal {
        assertEq(address(DEST.roleRegistry()), address(REGISTRY), "role registry after");
        assertFalse(DEST.paused(), "paused after");
        address[] memory holders = REGISTRY.roleHolders(uint256(DEST.TOP_UP_ROLE()));
        assertEq(holders[0], worker, "TOP_UP_ROLE holder");
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(DEST)), balances[i], "balance");
            assertEq(DEST.getDeposit(tokens[i]), deposits[i], "deposit");
        }
        for (uint256 i; i < samples.length; ++i) {
            Payout memory p = samples[i];
            assertTrue(DEST.isTransactionCompletedByTxId(p.txId), "historical completion by id");
            assertTrue(DEST.isTransactionCompleted(p.txHash, p.user, p.token), "historical completion");
            vm.expectRevert(TopUpDest.TopUpAlreadyProcessed.selector);
            vm.prank(worker);
            DEST.topUpUserSafe(p.txHash, p.user, p.chainId, p.token, p.amount);
        }
    }

    /// @dev Unsigned single and batch payouts still work on every sampled route; bad signed approvals still fail.
    ///      Runs inside a snapshot so balances are back for the next phase.
    function _assertPayouts(bool cosignerSet) internal {
        uint256 snap = vm.snapshotState();
        uint256 n = samples.length;
        bytes32[] memory hashes = new bytes32[](n);
        address[] memory users = new address[](n);
        uint256[] memory chainIds = new uint256[](n);
        address[] memory toks = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            Payout memory p = samples[i];
            uint256 amount = _simAmount(p);
            bytes32 single = keccak256(abi.encode("cosigner-3cp-single", i));
            uint256 before = IERC20(p.token).balanceOf(address(DEST));
            vm.prank(worker);
            DEST.topUpUserSafe(single, p.user, p.chainId, p.token, amount);
            assertTrue(DEST.isTransactionCompleted(single, p.user, p.token), "unsigned single completed");
            assertEq(IERC20(p.token).balanceOf(address(DEST)), before - amount, "unsigned single paid");
            (hashes[i], users[i], chainIds[i], toks[i], amounts[i]) = (keccak256(abi.encode("cosigner-3cp-batch", i)), p.user, p.chainId, p.token, amount);
        }
        vm.prank(worker);
        DEST.topUpUserSafeBatch(hashes, users, chainIds, toks, amounts);
        for (uint256 i; i < n; ++i) {
            assertTrue(DEST.isTransactionCompleted(hashes[i], users[i], toks[i]), "unsigned batch completed");
        }

        Payout memory s = samples[0];
        TopUpDest.TopUpApproval memory a = TopUpDest.TopUpApproval(keccak256("cosigner-3cp-signed"), s.user, s.chainId, s.token, _simAmount(s), block.timestamp + 300);
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(uint256(keccak256("not the cosigner")), DEST.getTopUpApprovalDigest(a));
        vm.expectRevert(cosignerSet ? TopUpDest.InvalidCosignature.selector : TopUpDest.InvalidCosigner.selector);
        vm.prank(worker);
        DEST.topUpUserSafeWithApproval(a, abi.encodePacked(r, sg, v));
        if (cosignerSet) {
            a.deadline = block.timestamp - 1;
            vm.expectRevert(TopUpDest.ApprovalExpired.selector);
            vm.prank(worker);
            DEST.topUpUserSafeWithApproval(a, abi.encodePacked(r, sg, v));
        }
        vm.revertToState(snap);
    }

    // ── Live sample of payouts, balances and deposits ──────────────────────────────

    function _snapshot() internal {
        worker = REGISTRY.roleHolders(uint256(DEST.TOP_UP_ROLE()))[0];
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = TOP_UP_EVENT;
        uint256 lookback = vm.envOr("TOP_UP_LOOKBACK", uint256(3000));
        for (uint256 end = block.number; end > block.number - lookback && samples.length < MAX_SAMPLES; end -= 10) {
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(end - 9, end, address(DEST), topics);
            for (uint256 i = logs.length; i > 0 && samples.length < MAX_SAMPLES; --i) {
                Vm.EthGetLogs memory l = logs[i - 1];
                (bytes32 txHash, uint256 chainId, uint256 amount) = abi.decode(l.data, (bytes32, uint256, uint256));
                address token = address(uint160(uint256(l.topics[3])));
                if (_seen(chainId, token)) continue;
                samples.push(Payout(l.topics[1], txHash, address(uint160(uint256(l.topics[2]))), token, chainId, amount));
                if (!_hasToken(token)) {
                    tokens.push(token);
                    balances.push(IERC20(token).balanceOf(address(DEST)));
                    deposits.push(DEST.getDeposit(token));
                }
                console.log("sample: source chain", chainId, "token", token);
            }
        }
        require(samples.length != 0, "no payouts in the lookback window; raise TOP_UP_LOOKBACK");
    }

    /// @dev A tenth of the original payout, capped at a tenth of the float, so every sampled route can pay twice
    function _simAmount(Payout memory p) internal view returns (uint256) {
        uint256 cap = IERC20(p.token).balanceOf(address(DEST)) / (4 * samples.length);
        uint256 amount = p.amount / 10;
        return amount == 0 ? 1 : (amount > cap ? cap : amount);
    }

    function _seen(uint256 chainId, address token) internal view returns (bool) {
        for (uint256 i; i < samples.length; ++i) {
            if (samples[i].chainId == chainId && samples[i].token == token) {
                return true;
            }
        }
        return false;
    }

    function _hasToken(address token) internal view returns (bool) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == token) {
                return true;
            }
        }
        return false;
    }

    // ── Bundle encoding ────────────────────────────────────────────────────────────

    function _schedule(address[] memory targets, bytes[] memory payloads, bytes32 salt, uint256 delay) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)", targets, new uint256[](targets.length), payloads, bytes32(0), salt, delay);
    }

    function _execute(address[] memory targets, bytes[] memory payloads, bytes32 salt) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, new uint256[](targets.length), payloads, bytes32(0), salt);
    }

    function _write(string memory step, address safe, bytes memory data) internal returns (string memory) {
        address timelock = safe == UPGRADE_SAFE ? UPGRADE_TIMELOCK : ADMIN_TIMELOCK;
        string memory json = string.concat(_getGnosisHeader("10", addressToHex(safe)), _getGnosisTransaction(addressToHex(timelock), iToHex(data), "0", true));
        vm.createDir("./output", true);
        string memory path = string.concat("./output/TopUpDestCosigner3CP-10-", step, ".json");
        vm.writeFile(path, json);
        console.log("Wrote", path);
        return path;
    }

    function _implOf() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(DEST), IMPL_SLOT))));
    }

    /// @dev UUPSUpgradeable bakes `address(this)` into an implementation; blank it before comparing builds
    function _blankSelf(bytes memory code, address self) internal pure returns (bytes memory) {
        bytes20 needle = bytes20(self);
        for (uint256 i; i + 20 <= code.length; ++i) {
            bool hit = true;
            for (uint256 j; j < 20 && hit; ++j) {
                hit = code[i + j] == needle[j];
            }
            if (hit) {
                for (uint256 j; j < 20; ++j) {
                    code[i + j] = 0;
                }
                i += 19;
            }
        }
        return code;
    }
}
