// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { TradingSafeLiquidDepositModule } from "../../src/trading-safe/TradingSafeLiquidDepositModule.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { RoleRegateProdConfig } from "./RoleRegateProdConfig.sol";

/// @title RoleRegateProd3CP
/// @notice Generates and fork-simulates the 3CP bundles that roll out cash-v3 #356 on prod: the COR-1794 re-gating,
///         the COR-1792 on-chain invariants, and the Certora Item 27 fixes. No broadcast call: it writes Safe
///         Transaction Builder JSONs to ./output and simulates them with prank.
///
///         The new Frax, Midas and TradingSafe Liquid deposit modules are enabled NEXT TO the live ones, with the live
///         constructor config. Their signature digests bind the module address, so cash-be must switch to the new
///         addresses; retiring the old modules is a later 3CP.
///
///         Optimism (10), two batches:
///           Upgrade batch, governance Safe 0xA6cf...AAC4 on the 2-day upgrade timelock (owner of the cash RoleRegistry):
///             nonce 143  upgradeTimelock.scheduleBatch
///             nonce 144  upgradeTimelock.executeBatch (not before 2 days after nonce 143 executes)
///             a. EtherFiDataProvider.upgradeToAndCall(new impl)
///             b. CashModule.setCashModuleSettersAddress(new CashModuleSetters)
///             c. LendGateway.upgradeToAndCall(new impl)
///             d. LiquidUSDLiquifierOP.upgradeToAndCall(new impl)
///             e. EtherFiDataProvider.configureDefaultModules([new Frax, new Midas], [true, true])  (also whitelists)
///             f. LendGateway.setDriver(new Frax, true)    (needs the RoleRegistry owner after c, audit I-03)
///             g. LendGateway.setDriver(new Midas, true)
///           Operating batch, Admin Timelock Safe 0x4799...240B on the 8-hour operating timelock (ADMIN_TIMELOCK_ROLE):
///             nonce 13  operatingTimelock.scheduleBatch
///             nonce 14  operatingTimelock.executeBatch, only AFTER the upgrade batch executes (it needs the new Frax
///                       module whitelisted; the simulation checks it reverts before)
///             a. CashModule.configureModulesCanRequestWithdraw([new Frax], [true])
///
///         Ethereum (1), governance Safe on the 2-day upgrade timelock (owner of the trading RoleRegistry):
///             nonce 78  upgradeTimelock.scheduleBatch
///             nonce 79  upgradeTimelock.executeBatch (not before 2 days after nonce 78 executes)
///             a. trading EtherFiDataProvider.upgradeToAndCall(new impl)
///             b. trading EtherFiDataProvider.configureDefaultModules([new deposit module], [true])
///
///         Nonces are the next free ones on 2026-10-31 (OP governance Safe queue ends at 142, Admin Timelock Safe at
///         12, Ethereum governance Safe at 77). Re-check them before creating the bundles; Safe Transaction Builder
///         files carry no nonce, so it is set when each bundle is created in the Safe UI.
///
///         If the contracts are not deployed yet (DeployRoleRegateProd.s.sol), the simulation deploys them on the
///         fork with the same salts and args; the real deploy is still a precondition for signing.
///
///         Bundles queued at other nonces on the same Safes can be replayed with PRIOR_BUNDLES (before this 3CP's
///         schedules) and BETWEEN_BUNDLES (after the delays, right before the executes). Each is a comma-separated
///         list of Transaction Builder files run in order; the entry WARP moves the fork 2 days ahead.
///
/// Usage (no broadcast). The Optimism run must link LendGateway to the pinned LendReserveLib:
///   ENV=mainnet forge script scripts/role-regate/RoleRegateProd3CP.s.sol --rpc-url $OPTIMISM_RPC \
///     --libraries src/modules/lend-gateway/LendReserveLib.sol:LendReserveLib:0xd65eCb4E22D578Bc732d51AAa4F0449D225fd723
///   ENV=mainnet forge script scripts/role-regate/RoleRegateProd3CP.s.sol --rpc-url $MAINNET_RPC
contract RoleRegateProd3CP is EtherFiDeployerHelper, GnosisHelpers, ContractCodeChecker, RoleRegateProdConfig {
    uint256 internal constant OP_GOV_SCHEDULE_NONCE = 143;
    uint256 internal constant OP_GOV_EXECUTE_NONCE = 144;
    uint256 internal constant OP_ATS_SCHEDULE_NONCE = 13;
    uint256 internal constant OP_ATS_EXECUTE_NONCE = 14;
    uint256 internal constant ETH_GOV_SCHEDULE_NONCE = 78;
    uint256 internal constant ETH_GOV_EXECUTE_NONCE = 79;

    bytes32 internal constant TL_PREDECESSOR = bytes32(0);
    bytes32 internal constant TL_SALT_OP_UPGRADE = keccak256("RoleRegate.OP.Upgrade.v1");
    bytes32 internal constant TL_SALT_OP_OPERATING = keccak256("RoleRegate.OP.Operating.v1");
    bytes32 internal constant TL_SALT_ETH_UPGRADE = keccak256("RoleRegate.ETH.Upgrade.v1");

    address[] internal targets;
    bytes[] internal payloads;
    address[] internal opTargets;
    bytes[] internal opPayloads;

    // Counts read right before the executes, so changes from bundles replayed in between are not attributed here
    uint256 internal whitelistedBefore;
    uint256 internal defaultsBefore;
    uint256 internal requestersBefore;

    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "prod only: ENV must be mainnet");
        console.log("Fork block:", block.number);
        _replayBundles("PRIOR_BUNDLES");
        if (block.chainid == 10) _runOptimism();
        else if (block.chainid == 1) _runEthereum();
        else revert("run on Optimism or Ethereum");
    }

    // ═══════════════════════════════ Optimism ═══════════════════════════════

    function _runOptimism() internal {
        RoleRegistry registry = RoleRegistry(OP_ROLE_REGISTRY);
        EtherFiDataProvider dp = EtherFiDataProvider(OP_DATA_PROVIDER);
        LendGateway gw = LendGateway(OP_LEND_GATEWAY);
        ICashModule cash = ICashModule(CASH_MODULE);

        // Governance preconditions
        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY);
        _checkTimelock(OPERATING_TIMELOCK, OPERATING_DELAY);
        _requireProposerExecutor(UPGRADE_TIMELOCK, GOVERNANCE_SAFE);
        _requireProposerExecutor(OPERATING_TIMELOCK, ADMIN_TIMELOCK_SAFE);
        require(registry.owner() == UPGRADE_TIMELOCK, "cash RoleRegistry owner is not the upgrade timelock");
        address[] memory atl = registry.roleHolders(registry.ADMIN_TIMELOCK_ROLE());
        require(atl.length == 1 && atl[0] == OPERATING_TIMELOCK, "ADMIN_TIMELOCK_ROLE is not held by exactly the operating timelock");

        // Live state this 3CP was written against
        require(_impl(OP_DATA_PROVIDER) == OLD_OP_DP_IMPL, "data provider not on the expected live impl");
        require(_impl(OP_LEND_GATEWAY) == OLD_GW_IMPL, "lend gateway not on the expected live impl");
        require(_impl(OP_LIQUIFIER) == OLD_LIQUIFIER_IMPL, "liquifier not on the expected live impl");
        require(CashModuleCore(CASH_MODULE).getCashModuleSetters() == OLD_SETTERS, "CashModule not on the expected live setters");
        require(dp.isDefaultModule(OLD_FRAX) && dp.isDefaultModule(OLD_MIDAS), "old modules are not default modules");
        require(gw.isDriver(OLD_FRAX) && gw.isDriver(OLD_MIDAS) && gw.isDriver(OP_LIQUIFIER), "old drivers changed");
        require(_isRequester(OLD_FRAX), "old Frax module is not a withdraw requester");

        _ensureOptimismContracts();
        require(!dp.isWhitelistedModule(NEW_FRAX) && !dp.isWhitelistedModule(NEW_MIDAS), "new module already whitelisted");
        require(!gw.isDriver(NEW_FRAX) && !gw.isDriver(NEW_MIDAS), "new module already a driver");

        _buildOptimismBatches();
        TimelockController up = TimelockController(payable(UPGRADE_TIMELOCK));
        TimelockController op = TimelockController(payable(OPERATING_TIMELOCK));
        bytes32 upId = up.hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, TL_SALT_OP_UPGRADE);
        bytes32 opId = op.hashOperationBatch(opTargets, new uint256[](opTargets.length), opPayloads, TL_PREDECESSOR, TL_SALT_OP_OPERATING);
        require(!up.isOperation(upId) && !op.isOperation(opId), "operation already scheduled");

        (string memory upSchedule, string memory upExecute) = _writeBundles(GOVERNANCE_SAFE, UPGRADE_TIMELOCK, targets, payloads, UPGRADE_DELAY, TL_SALT_OP_UPGRADE, OP_GOV_SCHEDULE_NONCE, OP_GOV_EXECUTE_NONCE, "op-upgrade");
        (string memory opSchedule, string memory opExecute) = _writeBundles(ADMIN_TIMELOCK_SAFE, OPERATING_TIMELOCK, opTargets, opPayloads, OPERATING_DELAY, TL_SALT_OP_OPERATING, OP_ATS_SCHEDULE_NONCE, OP_ATS_EXECUTE_NONCE, "op-operating");

        // Neither Safe can do any of it directly
        _expectRevert(GOVERNANCE_SAFE, OP_DATA_PROVIDER, payloads[0], "governance Safe upgraded the data provider directly");
        _expectRevert(GOVERNANCE_SAFE, CASH_MODULE, payloads[1], "governance Safe swapped the setters directly");
        _expectRevert(ADMIN_TIMELOCK_SAFE, CASH_MODULE, opPayloads[0], "Admin Timelock Safe configured a requester directly");

        console.log("=== Simulating schedules (governance Safe nonce 143, Admin Timelock Safe nonce 13) ===");
        executeGnosisTransactionBundle(upSchedule);
        executeGnosisTransactionBundle(opSchedule);
        require(up.isOperationPending(upId) && !up.isOperationReady(upId), "upgrade batch not pending after schedule");
        require(op.isOperationPending(opId) && !op.isOperationReady(opId), "operating batch not pending after schedule");

        // The operating batch is ready after 8 hours but must not execute before the upgrade batch
        vm.warp(block.timestamp + OPERATING_DELAY + 1);
        require(op.isOperationReady(opId), "operating batch not ready after 8 hours");
        _expectRevert(ADMIN_TIMELOCK_SAFE, OPERATING_TIMELOCK, _executeData(opTargets, opPayloads, TL_SALT_OP_OPERATING), "operating batch executed before the upgrade batch");
        _expectRevert(GOVERNANCE_SAFE, UPGRADE_TIMELOCK, _executeData(targets, payloads, TL_SALT_OP_UPGRADE), "upgrade batch executed after only 8 hours");

        vm.warp(block.timestamp + UPGRADE_DELAY);
        require(up.isOperationReady(upId), "upgrade batch not ready after 2 days");
        _replayBundles("BETWEEN_BUNDLES");

        whitelistedBefore = dp.getWhitelistedModules().length;
        defaultsBefore = dp.getDefaultModules().length;
        requestersBefore = cash.getWhitelistedModulesCanRequestWithdraw().length;

        console.log("=== Simulating execute (governance Safe nonce 144) ===");
        executeGnosisTransactionBundle(upExecute);
        require(up.isOperationDone(upId), "upgrade batch not done after execute");
        console.log("=== Simulating execute (Admin Timelock Safe nonce 14) ===");
        executeGnosisTransactionBundle(opExecute);
        require(op.isOperationDone(opId), "operating batch not done after execute");

        _assertOptimismEndState();
        _probeOptimismBehaviour();

        console.log("");
        console.log("  [OK] data provider, CashModuleSetters, LendGateway and LiquidUSDLiquifierOP upgraded");
        console.log("  [OK] new FraxModule enabled next to the live one:", NEW_FRAX);
        console.log("  [OK] new MidasModule enabled next to the live one:", NEW_MIDAS);
        console.log("2-day operation id:");
        console.logBytes32(upId);
        console.log("8h operation id:");
        console.logBytes32(opId);
    }

    function _buildOptimismBatches() internal {
        address[] memory mods = new address[](2);
        mods[0] = NEW_FRAX;
        mods[1] = NEW_MIDAS;
        bool[] memory yes2 = new bool[](2);
        yes2[0] = true;
        yes2[1] = true;

        targets.push(OP_DATA_PROVIDER);
        payloads.push(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (OP_DP_IMPL, "")));
        targets.push(CASH_MODULE);
        payloads.push(abi.encodeCall(CashModuleCore.setCashModuleSettersAddress, (NEW_SETTERS)));
        targets.push(OP_LEND_GATEWAY);
        payloads.push(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (NEW_GW_IMPL, "")));
        targets.push(OP_LIQUIFIER);
        payloads.push(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (NEW_LIQUIFIER_IMPL, "")));
        targets.push(OP_DATA_PROVIDER);
        payloads.push(abi.encodeCall(EtherFiDataProvider.configureDefaultModules, (mods, yes2)));
        targets.push(OP_LEND_GATEWAY);
        payloads.push(abi.encodeCall(LendGateway.setDriver, (NEW_FRAX, true)));
        targets.push(OP_LEND_GATEWAY);
        payloads.push(abi.encodeCall(LendGateway.setDriver, (NEW_MIDAS, true)));

        address[] memory frax = new address[](1);
        frax[0] = NEW_FRAX;
        bool[] memory yes1 = new bool[](1);
        yes1[0] = true;
        opTargets.push(CASH_MODULE);
        opPayloads.push(abi.encodeCall(ICashModule.configureModulesCanRequestWithdraw, (frax, yes1)));
    }

    function _assertOptimismEndState() internal view {
        EtherFiDataProvider dp = EtherFiDataProvider(OP_DATA_PROVIDER);
        LendGateway gw = LendGateway(OP_LEND_GATEWAY);
        ICashModule cash = ICashModule(CASH_MODULE);

        require(_impl(OP_DATA_PROVIDER) == OP_DP_IMPL, "data provider not on the new impl");
        require(_impl(OP_LEND_GATEWAY) == NEW_GW_IMPL, "lend gateway not on the new impl");
        require(_impl(OP_LIQUIFIER) == NEW_LIQUIFIER_IMPL, "liquifier not on the new impl");
        require(CashModuleCore(CASH_MODULE).getCashModuleSetters() == NEW_SETTERS, "CashModule not on the new setters");

        require(dp.isWhitelistedModule(NEW_FRAX) && dp.isDefaultModule(NEW_FRAX), "new Frax not whitelisted and default");
        require(dp.isWhitelistedModule(NEW_MIDAS) && dp.isDefaultModule(NEW_MIDAS), "new Midas not whitelisted and default");
        require(dp.getWhitelistedModules().length == whitelistedBefore + 2, "whitelist changed by more than the new modules");
        require(dp.getDefaultModules().length == defaultsBefore + 2, "default set changed by more than the new modules");
        require(dp.isDefaultModule(OLD_FRAX) && dp.isDefaultModule(OLD_MIDAS), "an old module was disabled");

        require(gw.isDriver(NEW_FRAX) && gw.isDriver(NEW_MIDAS), "new modules are not gateway drivers");
        require(gw.isDriver(OLD_FRAX) && gw.isDriver(OLD_MIDAS) && gw.isDriver(OP_LIQUIFIER), "an existing driver was revoked");
        require(address(gw.spoke()) == AAVE_SPOKE, "gateway spoke changed across the upgrade");

        require(_isRequester(NEW_FRAX), "new Frax cannot request withdrawals");
        require(_isRequester(OLD_FRAX), "old Frax lost withdraw requests");
        require(!_isRequester(NEW_MIDAS), "new Midas became a withdraw requester; the live one is not");
        require(cash.getWhitelistedModulesCanRequestWithdraw().length == requestersBefore + 1, "requesters changed by more than the new Frax");

        (address[] memory tokens,,) = _midasArgs();
        for (uint256 i = 0; i < tokens.length; ++i) {
            (address d1, address r1) = MidasModule(NEW_MIDAS).vaults(tokens[i]);
            (address d0, address r0) = MidasModule(OLD_MIDAS).vaults(tokens[i]);
            require(d1 == d0 && r1 == r0, "new Midas vaults differ from the live module");
            require(MidasModule(NEW_MIDAS).everConfigured(tokens[i]), "new Midas token not marked configured");
        }
        FraxModule f = FraxModule(NEW_FRAX);
        require(f.fraxusd() == FRAXUSD && f.custodian() == FRAX_CUSTODIAN && f.remoteHop() == FRAX_REMOTE_HOP, "new Frax args differ");

        require(RoleRegistry(OP_ROLE_REGISTRY).owner() == UPGRADE_TIMELOCK, "cash RoleRegistry owner changed");
    }

    /// @dev Checks the re-gates on the upgraded contracts, then restores what it changed
    function _probeOptimismBehaviour() internal {
        LendGateway gw = LendGateway(OP_LEND_GATEWAY);
        address probe = address(0xD71BE5);

        // I-03: authorizing a driver needs the RoleRegistry owner, ADMIN_TIMELOCK_ROLE can still revoke
        vm.prank(OPERATING_TIMELOCK);
        vm.expectRevert(UpgradeableProxy.OnlyRoleRegistryOwner.selector);
        gw.setDriver(probe, true);
        vm.prank(UPGRADE_TIMELOCK);
        gw.setDriver(probe, true);
        vm.prank(OPERATING_TIMELOCK);
        gw.setDriver(probe, false);
        require(!gw.isDriver(probe), "driver probe left authorized");

        // COR-1792: the gateway only pays the safe, a settlement dispatcher or (borrow) the DebtManager
        ICashModule cash = ICashModule(CASH_MODULE);
        require(!cash.isAllowedLendRecipient(probe, true), "an arbitrary address is an allowed lend recipient");
        require(cash.isAllowedLendRecipient(DEBT_MANAGER, true) && !cash.isAllowedLendRecipient(DEBT_MANAGER, false), "DebtManager recipient rule wrong");

        // L-01: re-registering a configured Midas token needs the RoleRegistry owner, removal does not reopen it
        (address[] memory tokens, address[] memory deposits, address[] memory redemptions) = _midasArgs();
        address[] memory one = new address[](1);
        one[0] = tokens[0];
        address[] memory d = new address[](1);
        d[0] = deposits[0];
        address[] memory r = new address[](1);
        r[0] = redemptions[0];
        vm.prank(OPERATING_TIMELOCK);
        vm.expectRevert(MidasModule.Unauthorized.selector);
        MidasModule(NEW_MIDAS).addMidasVaults(one, d, r);
    }

    /// @dev Deploys on the fork whatever the real deploy has not placed yet, then checks code against this source tree
    function _ensureOptimismContracts() internal {
        if (LEND_RESERVE_LIB.code.length == 0 || NEW_FRAX.code.length == 0) {
            console.log("WARNING: Optimism contracts not all deployed on-chain yet; deploying the missing ones on the fork only");
        }
        address deployer = DEPLOYER.getDeployers()[0];
        vm.startPrank(deployer);
        _create3(LIB_SALT, vm.getCode("LendReserveLib.sol:LendReserveLib"), "");
        _create3(OP_DP_IMPL_SALT, type(EtherFiDataProvider).creationCode, "");
        _create3(SETTERS_SALT, type(CashModuleSetters).creationCode, abi.encode(OP_DATA_PROVIDER));
        _create3(GW_IMPL_SALT, type(LendGateway).creationCode, abi.encode(OP_DATA_PROVIDER, AAVE_SPOKE));
        _create3(LIQUIFIER_IMPL_SALT, type(LiquidUSDLiquifierOPModule).creationCode, abi.encode(DEBT_MANAGER, OP_DATA_PROVIDER));
        _create3(FRAX_SALT, type(FraxModule).creationCode, abi.encode(OP_DATA_PROVIDER, FRAXUSD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP));
        (address[] memory tokens, address[] memory deposits, address[] memory redemptions) = _midasArgs();
        _create3(MIDAS_SALT, type(MidasModule).creationCode, abi.encode(OP_DATA_PROVIDER, tokens, deposits, redemptions));
        vm.stopPrank();

        require(_predictAddress(LIB_SALT) == LEND_RESERVE_LIB && _predictAddress(GW_IMPL_SALT) == NEW_GW_IMPL, "salt pins moved");
        require(_codeContainsAddress(NEW_GW_IMPL, LEND_RESERVE_LIB), "LendGateway impl is not linked to the pinned LendReserveLib: pass --libraries");
        requireCodeMatchAllowingAddressEmbeds("EtherFiDataProviderImpl", OP_DP_IMPL, address(new EtherFiDataProvider()));
        requireCodeMatchAllowingAddressEmbeds("CashModuleSetters", NEW_SETTERS, address(new CashModuleSetters(OP_DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("LendGatewayImpl", NEW_GW_IMPL, address(new LendGateway(OP_DATA_PROVIDER, AAVE_SPOKE)));
        requireCodeMatchAllowingAddressEmbeds("LiquidUSDLiquifierOPImpl", NEW_LIQUIFIER_IMPL, address(new LiquidUSDLiquifierOPModule(DEBT_MANAGER, OP_DATA_PROVIDER)));
        requireExactCodeMatch("FraxModule", NEW_FRAX, address(new FraxModule(OP_DATA_PROVIDER, FRAXUSD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP)));
        requireExactCodeMatch("MidasModule", NEW_MIDAS, address(new MidasModule(OP_DATA_PROVIDER, tokens, deposits, redemptions)));
    }

    function _isRequester(address module) internal view returns (bool) {
        address[] memory list = ICashModule(CASH_MODULE).getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == module) return true;
        }
        return false;
    }

    // ═══════════════════════════════ Ethereum ═══════════════════════════════

    function _runEthereum() internal {
        RoleRegistry registry = RoleRegistry(ETH_ROLE_REGISTRY);
        EtherFiDataProvider dp = EtherFiDataProvider(ETH_DATA_PROVIDER);

        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY);
        _requireProposerExecutor(UPGRADE_TIMELOCK, GOVERNANCE_SAFE);
        require(registry.owner() == UPGRADE_TIMELOCK, "trading RoleRegistry owner is not the upgrade timelock");
        require(_impl(ETH_DATA_PROVIDER) == OLD_ETH_DP_IMPL, "trading data provider not on the expected live impl");
        require(dp.isDefaultModule(OLD_DEPOSIT_MODULE), "old deposit module is not a default module");

        _ensureEthereumContracts();
        require(!dp.isWhitelistedModule(NEW_DEPOSIT_MODULE), "new deposit module already whitelisted");

        address[] memory mods = new address[](1);
        mods[0] = NEW_DEPOSIT_MODULE;
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        targets.push(ETH_DATA_PROVIDER);
        payloads.push(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (ETH_DP_IMPL, "")));
        targets.push(ETH_DATA_PROVIDER);
        payloads.push(abi.encodeCall(EtherFiDataProvider.configureDefaultModules, (mods, yes)));

        TimelockController tl = TimelockController(payable(UPGRADE_TIMELOCK));
        bytes32 id = tl.hashOperationBatch(targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, TL_SALT_ETH_UPGRADE);
        require(!tl.isOperation(id), "operation already scheduled");
        (string memory schedulePath, string memory executePath) = _writeBundles(GOVERNANCE_SAFE, UPGRADE_TIMELOCK, targets, payloads, UPGRADE_DELAY, TL_SALT_ETH_UPGRADE, ETH_GOV_SCHEDULE_NONCE, ETH_GOV_EXECUTE_NONCE, "eth-upgrade");

        _expectRevert(GOVERNANCE_SAFE, ETH_DATA_PROVIDER, payloads[0], "governance Safe upgraded the trading data provider directly");

        console.log("=== Simulating schedule (governance Safe nonce 78) ===");
        executeGnosisTransactionBundle(schedulePath);
        require(tl.isOperationPending(id) && !tl.isOperationReady(id), "operation not pending after schedule");
        vm.warp(block.timestamp + OPERATING_DELAY + 1);
        _expectRevert(GOVERNANCE_SAFE, UPGRADE_TIMELOCK, _executeData(targets, payloads, TL_SALT_ETH_UPGRADE), "executeBatch succeeded after only 8 hours");
        vm.warp(block.timestamp + UPGRADE_DELAY);
        require(tl.isOperationReady(id), "operation not ready after 2 days");
        _replayBundles("BETWEEN_BUNDLES");

        whitelistedBefore = dp.getWhitelistedModules().length;
        defaultsBefore = dp.getDefaultModules().length;

        console.log("=== Simulating execute (governance Safe nonce 79) ===");
        executeGnosisTransactionBundle(executePath);
        require(tl.isOperationDone(id), "operation not done after execute");

        require(_impl(ETH_DATA_PROVIDER) == ETH_DP_IMPL, "trading data provider not on the new impl");
        require(dp.isWhitelistedModule(NEW_DEPOSIT_MODULE) && dp.isDefaultModule(NEW_DEPOSIT_MODULE), "new deposit module not whitelisted and default");
        require(dp.getWhitelistedModules().length == whitelistedBefore + 1, "whitelist changed by more than the new module");
        require(dp.getDefaultModules().length == defaultsBefore + 1, "default set changed by more than the new module");
        require(dp.isDefaultModule(OLD_DEPOSIT_MODULE), "old deposit module was disabled");
        require(address(TradingSafeLiquidDepositModule(NEW_DEPOSIT_MODULE).liquidAssetToTeller(LIQUID_BTC)) == LIQUID_BTC_TELLER, "new deposit module teller differs");
        require(registry.owner() == UPGRADE_TIMELOCK, "trading RoleRegistry owner changed");

        console.log("");
        console.log("  [OK] trading EtherFiDataProvider upgraded to", ETH_DP_IMPL);
        console.log("  [OK] new TradingSafeLiquidDepositModule enabled next to the live one:", NEW_DEPOSIT_MODULE);
        console.log("2-day operation id:");
        console.logBytes32(id);
    }

    function _ensureEthereumContracts() internal {
        if (NEW_DEPOSIT_MODULE.code.length == 0 || ETH_DP_IMPL.code.length == 0) {
            console.log("WARNING: Ethereum contracts not all deployed on-chain yet; deploying the missing ones on the fork only");
        }
        (address[] memory assets, address[] memory tellers) = _depositArgs();
        vm.startPrank(DEPLOYER.getDeployers()[0]);
        _create3(ETH_DP_IMPL_SALT, type(EtherFiDataProvider).creationCode, "");
        _create3(DEPOSIT_SALT, type(TradingSafeLiquidDepositModule).creationCode, abi.encode(assets, tellers, ETH_DATA_PROVIDER));
        vm.stopPrank();
        require(_predictAddress(DEPOSIT_SALT) == NEW_DEPOSIT_MODULE && _predictAddress(ETH_DP_IMPL_SALT) == ETH_DP_IMPL, "salt pins moved");
        requireCodeMatchAllowingAddressEmbeds("TradingEtherFiDataProviderImpl", ETH_DP_IMPL, address(new EtherFiDataProvider()));
        requireExactCodeMatch("TradingSafeLiquidDepositModule", NEW_DEPOSIT_MODULE, address(new TradingSafeLiquidDepositModule(assets, tellers, ETH_DATA_PROVIDER)));
    }

    // ═══════════════════════════════ shared ═══════════════════════════════

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }

    function _replayBundles(string memory envKey) internal {
        string[] memory entries = vm.envOr(envKey, ",", new string[](0));
        for (uint256 i = 0; i < entries.length; ++i) {
            if (isEqualString(entries[i], "WARP")) {
                vm.warp(block.timestamp + UPGRADE_DELAY + 1);
                console.log(envKey, ": warped 2 days");
                continue;
            }
            require(vm.parseJsonUint(vm.readFile(entries[i]), ".chainId") == block.chainid, "replayed bundle is for another chain");
            executeGnosisTransactionBundle(entries[i]);
            console.log(envKey, "replayed:", entries[i]);
        }
    }

    function _checkTimelock(address timelock, uint256 delay) internal view {
        require(keccak256(timelock.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local build");
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(tl.getMinDelay() == delay, "timelock: unexpected delay");
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), timelock), "timelock is not its own admin");
    }

    function _requireProposerExecutor(address timelock, address safe) internal view {
        EtherFiTimelock tl = EtherFiTimelock(payable(timelock));
        require(tl.hasRole(tl.PROPOSER_ROLE(), safe) && tl.hasRole(tl.EXECUTOR_ROLE(), safe), "Safe is not a proposer and executor on the timelock");
    }

    function _scheduleData(address[] storage t, bytes[] storage p, uint256 delay, bytes32 salt) internal view returns (bytes memory) {
        return abi.encodeCall(TimelockController.scheduleBatch, (t, new uint256[](t.length), p, TL_PREDECESSOR, salt, delay));
    }

    function _executeData(address[] storage t, bytes[] storage p, bytes32 salt) internal view returns (bytes memory) {
        return abi.encodeCall(TimelockController.executeBatch, (t, new uint256[](t.length), p, TL_PREDECESSOR, salt));
    }

    function _writeBundles(address safe, address timelock, address[] storage t, bytes[] storage p, uint256 delay, bytes32 salt, uint256 scheduleNonce, uint256 executeNonce, string memory label) internal returns (string memory schedulePath, string memory executePath) {
        string memory prefix = string.concat("./output/RoleRegate-", label, "-", vm.toString(block.chainid), "-");
        schedulePath = string.concat(prefix, "nonce", vm.toString(scheduleNonce), "-schedule.json");
        executePath = string.concat(prefix, "nonce", vm.toString(executeNonce), "-execute.json");
        _writeBundle(schedulePath, safe, timelock, _scheduleData(t, p, delay, salt));
        _writeBundle(executePath, safe, timelock, _executeData(t, p, salt));
    }

    function _writeBundle(string memory path, address safe, address timelock, bytes memory data) internal {
        string memory header = _getGnosisHeader(vm.toString(block.chainid), addressToHex(safe));
        vm.writeFile(path, string.concat(header, _getGnosisTransaction(addressToHex(timelock), iToHex(data), "0", true)));
        console.log("Wrote", path);
    }

    function _expectRevert(address from, address to, bytes memory data, string memory err) internal {
        vm.prank(from);
        (bool ok,) = to.call(data);
        require(!ok, err);
    }
}
