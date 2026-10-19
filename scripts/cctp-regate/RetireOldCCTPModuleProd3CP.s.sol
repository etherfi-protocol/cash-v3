// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { CCTPModule } from "../../src/modules/cctp/CCTPModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

interface ISafeHashes {
    function nonce() external view returns (uint256);
    function domainSeparator() external view returns (bytes32);
    function getTransactionHash(address to, uint256 value, bytes calldata data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, uint256 _nonce)
        external
        view
        returns (bytes32);
}

/// @title RetireOldCCTPModuleProd3CP
/// @notice Generates and fork-simulates the Optimism 3CP that retires the pre-re-gating CCTPModule. It contains no
///         broadcast call: it only writes Safe Transaction Builder JSONs to ./output and simulates them with prank.
///
///         Admin Safe 0x4799...240B (3/6), a proposer and executor on the 8h operating timelock:
///           nonce 6  operatingTimelock.scheduleBatch
///           nonce 7  operatingTimelock.executeBatch (not before 8 hours after nonce 6 executes)
///         The batch removes the old module from every place it is enabled, requesters first:
///           a. CashModule.configureModulesCanRequestWithdraw([old], [false])
///           b. LendGateway.setDriver(old OpenOcean, false)
///           c. EtherFiDataProvider.configureModules([old CCTP, old OpenOcean], [false, false])  (also removes both
///              from the default set)
///         The new OpenOcean module registered by 3CP-725 is not touched.
///
///         Upgrade Safe 0xBAf0...2588 (4/7), a proposer and executor on the 2-day upgrade timelock, which owns the
///         cash RoleRegistry:
///           nonce 4  upgradeTimelock.scheduleBatch
///           nonce 6  upgradeTimelock.executeBatch (not before 2 days after nonce 4 executes)
///         Nonce 5 is left for another transaction. Safe nonces run in order, so the simulation marks nonce 5 as
///         used (a no-op) before the execute at nonce 6.
///         The batch revokes CCTP_MODULE_ADMIN_ROLE from the cash controller Safe 0xA6cf...AAC4, its only holder:
///           a. cash RoleRegistry.revokeRole(CCTP_MODULE_ADMIN_ROLE, AAC4)
///
///         Safe Transaction Builder files carry no nonce; the nonce is in each file name and must be set when the
///         bundle is created in the Safe UI. Each Safe tx hash is read from the Safe's own getTransactionHash and
///         checked against one built from the domain separator and the SafeTx struct.
///
/// Usage (no broadcast):
///   ENV=mainnet forge script scripts/cctp-regate/RetireOldCCTPModuleProd3CP.s.sol --rpc-url $OPTIMISM_RPC
contract RetireOldCCTPModuleProd3CP is EtherFiDeployerHelper, GnosisHelpers {
    using stdJson for string;

    // ─────────────────────────────── governance ───────────────────────────────

    address internal constant GOVERNANCE_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant ADMIN_SAFE = 0x47992A4E7920EE57eb3dD06131C1a086963b240B;
    address internal constant UPGRADE_SAFE = 0xBAf0E1af05c5ab8Bb709d13e1B6DeDd53b492588;
    address internal constant OPERATING_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    address internal constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    uint256 internal constant OPERATING_DELAY = 8 hours;
    uint256 internal constant UPGRADE_DELAY = 2 days;

    uint256 internal constant ADMIN_SCHEDULE_NONCE = 6;
    uint256 internal constant ADMIN_EXECUTE_NONCE = 7;
    uint256 internal constant UPGRADE_SCHEDULE_NONCE = 4;
    uint256 internal constant UPGRADE_EXECUTE_NONCE = 6;

    bytes32 internal constant TL_PREDECESSOR = bytes32(0);
    bytes32 internal constant TL_SALT_RETIRE = keccak256("CCTPRegate.OP.RetireOldCCTPAndOpenOcean.v1");
    bytes32 internal constant TL_SALT_ROLE = keccak256("CCTPRegate.OP.RevokeCCTPModuleAdminRole.v1");

    bytes32 internal constant SAFE_TX_TYPEHASH = keccak256("SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)");

    // ─────────────────────────────── Optimism ───────────────────────────────

    address internal constant OLD_MODULE = 0xFEF147ce61614aa787B6E68c24Ff096D13593A9d;
    address internal constant NEW_MODULE = 0xD3f5c617EF328b73130467b0ec867aD9058a1784;
    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant OLD_OPENOCEAN = 0x850D01FfCD8d23fA29751Eb26F8A473FFa4FFD0A;
    address internal constant NEW_OPENOCEAN = 0xFec8640113C5ff6c28A9aBAE5162f8602D8BD4bF;
    address internal constant LEND_GATEWAY = 0x01F8cDFb1694eA8fE4ED6c38a0fD78d1188E03F4;
    bytes32 internal constant CCTP_MODULE_ADMIN_ROLE = 0xb817fb5ee552a2466b9ad53344de1868ec13e9ead5f256ef1fb9b0911888f2f4;
    uint32[4] internal NEW_ROUTES = [0, 3, 6, 19];
    /// @dev Highest CCTP domain checked when comparing route sets
    uint32 internal constant MAX_DOMAIN = 31;

    // Every other role constant in the cash code, current and removed by the re-gating. Their holders must not change.
    string[32] internal OTHER_ROLES = [
        "ADMIN_ROLE",
        "ADMIN_TIMELOCK_ROLE",
        "CASHBACK_DISTRIBUTOR_ROLE",
        "DEPOSITOR_ROLE",
        "ETHERFI_SAFE_FACTORY_ADMIN_ROLE",
        "ETHER_FI_WALLET_ROLE",
        "PAUSER",
        "RAMP_VOLUME_EMITTER_ROLE",
        "SETTLEMENT_DISPATCHER_BRIDGER_ROLE",
        "TOPUP_FACTORY_BRIDGER_ROLE",
        "TOPUP_FACTORY_REDIRECT_ROLE",
        "TOP_UP_ROLE",
        "TRADING_SAFE_FACTORY_ADMIN_ROLE",
        "TRADING_SAFE_LIQUID_DEPOSIT_MODULE_ADMIN",
        "TRADING_SAFE_REDIRECT_ROLE",
        "UNPAUSER",
        "ACROSS_SWAP_MODULE_ADMIN_ROLE",
        "BEHYPE_STAKE_MODULE_ADMIN_ROLE",
        "CASHBACK_DISPATCHER_ADMIN_ROLE",
        "CASH_MODULE_CONTROLLER_ROLE",
        "DATA_PROVIDER_ADMIN_ROLE",
        "DEBT_MANAGER_ADMIN_ROLE",
        "ENSO_SWAP_MODULE_ADMIN_ROLE",
        "ETHERFI_LIQUID_MODULE_ADMIN",
        "LEND_GATEWAY_ADMIN_ROLE",
        "MIDAS_MODULE_ADMIN",
        "PRICE_PROVIDER_ADMIN_ROLE",
        "STARGATE_MODULE_ADMIN_ROLE",
        "STOCK_UNWRAPPER_ADMIN_ROLE",
        "STOCK_WITHDRAW_MODULE_ADMIN_ROLE",
        "TRADING_LENS_ADMIN_ROLE",
        "WORMHOLE_MODULE_ADMIN_ROLE"
    ];

    // Every address LendGateway has ever emitted DriverSet for (LendGateway has no driver list), read from its logs
    address[] internal DRIVER_CANDIDATES = [0x0078C5a459132e279056B2371fE8A8eC973A9553, 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87, 0x850D01FfCD8d23fA29751Eb26F8A473FFa4FFD0A, 0x427fDe7FF5D685e76f572BDFb896184a2048f232, 0xA051246A613E3216DD90402453D3B8aD63E71Cd1, 0x3C97a4899a92b7e84d92c5032dC7d865E7471EcE, 0xD4F81cF925248513631723A5cd0a8842f8cC2C3E, 0x80b14dC43d257C6bC7487249095F1435d43fC591, 0x46E9aF4DC3D4535AfCbeb408Db564D729F527bD8, 0x39161A44588ec2327a18D4707EA5216C721ba539, 0xac6BcA0bB66D4587171CFc77b19E5E68F74De55e, 0x241D0227e6Ae4df1747f2A04F4bF3d33eD850cA7, 0x162c9f902867308B6f92c80B7329f5883385FC87, 0xf4d5Be5CfcCE8C32785FC36bF3851D2f1E3C0154, 0x48651bf1ED1eE15C7493a79188E3326602b321c4, 0xd2fBD2fCac7e88ef323694e617141Efb20140c56, 0x1052fDcE6CBE3D2AD265050e1426D41E23fc54dc, 0xFec8640113C5ff6c28A9aBAE5162f8602D8BD4bF];

    address[] internal retireTargets;
    bytes[] internal retirePayloads;
    address[] internal roleTargets;
    bytes[] internal rolePayloads;

    EtherFiDataProvider internal dataProvider;
    ICashModule internal cashModule;
    ILendGatewayDrivers internal lendGateway;
    RoleRegistry internal cashRegistry;

    address[] internal whitelistedBefore;
    address[] internal defaultsBefore;
    address[] internal requestersBefore;
    bool[] internal driverBefore;
    bytes32[] internal otherRoleDigests;

    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "prod only: ENV must be mainnet");
        require(block.chainid == 10, "run on Optimism");
        console.log("Fork block:", block.number);

        string memory dep = readDeploymentFile();
        dataProvider = EtherFiDataProvider(dep.readAddress(".addresses.EtherFiDataProvider"));
        cashModule = ICashModule(dep.readAddress(".addresses.CashModule"));
        cashRegistry = RoleRegistry(dep.readAddress(".addresses.RoleRegistry"));
        lendGateway = ILendGatewayDrivers(dep.readAddress(".addresses.LendGateway"));
        require(address(lendGateway) == LEND_GATEWAY, "LendGateway differs from the pinned address");

        _checkGovernance();
        _checkBefore();
        _buildBatches();

        TimelockController opTl = TimelockController(payable(OPERATING_TIMELOCK));
        TimelockController upTl = TimelockController(payable(UPGRADE_TIMELOCK));
        bytes32 retireId = opTl.hashOperationBatch(retireTargets, new uint256[](retireTargets.length), retirePayloads, TL_PREDECESSOR, TL_SALT_RETIRE);
        bytes32 roleId = upTl.hashOperationBatch(roleTargets, new uint256[](roleTargets.length), rolePayloads, TL_PREDECESSOR, TL_SALT_ROLE);
        require(!opTl.isOperation(retireId), "retire operation already scheduled");
        require(!upTl.isOperation(roleId), "role operation already scheduled");

        string[4] memory paths = _writeAndHash();
        _expectNoDirectAccess();
        _simulate(retireId, roleId, paths);
        _assertAfter();

        console.log("");
        console.log("  [OK] old CCTPModule retired:", OLD_MODULE);
        console.log("  [OK] old OpenOcean module retired:", OLD_OPENOCEAN);
        console.log("  [OK] CCTP_MODULE_ADMIN_ROLE revoked from", GOVERNANCE_SAFE);
        console.log("8h operation id:");
        console.logBytes32(retireId);
        console.log("2-day operation id:");
        console.logBytes32(roleId);
    }

    function _checkGovernance() internal view {
        _checkTimelock(OPERATING_TIMELOCK, OPERATING_DELAY);
        _checkTimelock(UPGRADE_TIMELOCK, UPGRADE_DELAY);
        EtherFiTimelock opTl = EtherFiTimelock(payable(OPERATING_TIMELOCK));
        EtherFiTimelock upTl = EtherFiTimelock(payable(UPGRADE_TIMELOCK));
        require(opTl.hasRole(opTl.PROPOSER_ROLE(), ADMIN_SAFE) && opTl.hasRole(opTl.EXECUTOR_ROLE(), ADMIN_SAFE), "Admin Safe is not proposer and executor on the operating timelock");
        require(upTl.hasRole(upTl.PROPOSER_ROLE(), UPGRADE_SAFE) && upTl.hasRole(upTl.EXECUTOR_ROLE(), UPGRADE_SAFE), "Upgrade Safe is not proposer and executor on the upgrade timelock");
        require(cashRegistry.owner() == UPGRADE_TIMELOCK, "cash RoleRegistry owner is not the upgrade timelock");
        address[] memory atl = cashRegistry.roleHolders(cashRegistry.ADMIN_TIMELOCK_ROLE());
        require(atl.length == 1 && atl[0] == OPERATING_TIMELOCK, "ADMIN_TIMELOCK_ROLE is not held by exactly the operating timelock");
        require(CCTP_MODULE_ADMIN_ROLE == keccak256("CCTP_MODULE_ADMIN_ROLE"), "unexpected CCTP_MODULE_ADMIN_ROLE hash");
        require(ISafeHashes(ADMIN_SAFE).nonce() <= ADMIN_SCHEDULE_NONCE, "Admin Safe schedule nonce already used");
        require(ISafeHashes(UPGRADE_SAFE).nonce() <= UPGRADE_SCHEDULE_NONCE, "Upgrade Safe schedule nonce already used");
    }

    function _checkBefore() internal {
        require(dataProvider.isWhitelistedModule(OLD_MODULE) && dataProvider.isDefaultModule(OLD_MODULE), "old module is not whitelisted and default");
        require(_contains(cashModule.getWhitelistedModulesCanRequestWithdraw(), OLD_MODULE), "old module is not a withdraw requester");
        address[] memory holders = cashRegistry.roleHolders(CCTP_MODULE_ADMIN_ROLE);
        require(holders.length == 1 && holders[0] == GOVERNANCE_SAFE, "CCTP_MODULE_ADMIN_ROLE is not held by exactly the governance Safe");
        require(IERC20Balance(USDC).balanceOf(OLD_MODULE) == 0 && OLD_MODULE.balance == 0, "old module holds funds");

        require(dataProvider.isWhitelistedModule(OLD_OPENOCEAN) && dataProvider.isDefaultModule(OLD_OPENOCEAN) && lendGateway.isDriver(OLD_OPENOCEAN), "old OpenOcean is not whitelisted, default and a driver");
        require(!_contains(cashModule.getWhitelistedModulesCanRequestWithdraw(), OLD_OPENOCEAN), "old OpenOcean is a withdraw requester");
        require(IERC20Balance(USDC).balanceOf(OLD_OPENOCEAN) == 0 && OLD_OPENOCEAN.balance == 0, "old OpenOcean holds funds");
        require(dataProvider.isWhitelistedModule(NEW_OPENOCEAN) && dataProvider.isDefaultModule(NEW_OPENOCEAN) && lendGateway.isDriver(NEW_OPENOCEAN), "new OpenOcean is not whitelisted, default and a driver");
        require(dataProvider.isWhitelistedModule(NEW_MODULE) && dataProvider.isDefaultModule(NEW_MODULE), "new module is not whitelisted and default");
        require(_contains(cashModule.getWhitelistedModulesCanRequestWithdraw(), NEW_MODULE), "new module is not a withdraw requester");

        whitelistedBefore = dataProvider.getWhitelistedModules();
        defaultsBefore = dataProvider.getDefaultModules();
        requestersBefore = cashModule.getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < DRIVER_CANDIDATES.length; ++i) driverBefore.push(lendGateway.isDriver(DRIVER_CANDIDATES[i]));
        for (uint256 i = 0; i < OTHER_ROLES.length; ++i) {
            otherRoleDigests.push(keccak256(abi.encode(cashRegistry.roleHolders(keccak256(bytes(OTHER_ROLES[i]))))));
        }
        console.log("whitelisted / default / requesters before:", whitelistedBefore.length, defaultsBefore.length, requestersBefore.length);
    }

    function _buildBatches() internal {
        address[] memory m = new address[](1);
        m[0] = OLD_MODULE;
        bool[] memory no = new bool[](1);
        retireTargets.push(address(cashModule));
        retirePayloads.push(abi.encodeCall(ICashModule.configureModulesCanRequestWithdraw, (m, no)));
        retireTargets.push(LEND_GATEWAY);
        retirePayloads.push(abi.encodeCall(ILendGatewayDrivers.setDriver, (OLD_OPENOCEAN, false)));
        address[] memory both = new address[](2);
        both[0] = OLD_MODULE;
        both[1] = OLD_OPENOCEAN;
        bool[] memory noNo = new bool[](2);
        retireTargets.push(address(dataProvider));
        retirePayloads.push(abi.encodeCall(EtherFiDataProvider.configureModules, (both, noNo)));
        roleTargets.push(address(cashRegistry));
        rolePayloads.push(abi.encodeCall(RoleRegistry.revokeRole, (CCTP_MODULE_ADMIN_ROLE, GOVERNANCE_SAFE)));
    }

    function _expectNoDirectAccess() internal {
        address[3] memory safes = [GOVERNANCE_SAFE, ADMIN_SAFE, UPGRADE_SAFE];
        for (uint256 i = 0; i < 3; ++i) {
            _expectRevert(safes[i], address(cashModule), retirePayloads[0], "a Safe removed the requester directly");
            _expectRevert(safes[i], LEND_GATEWAY, retirePayloads[1], "a Safe removed the driver directly");
            _expectRevert(safes[i], address(dataProvider), retirePayloads[2], "a Safe removed the modules directly");
            _expectRevert(safes[i], address(cashRegistry), rolePayloads[0], "a Safe revoked the role directly");
        }
    }

    function _simulate(bytes32 retireId, bytes32 roleId, string[4] memory paths) internal {
        TimelockController opTl = TimelockController(payable(OPERATING_TIMELOCK));
        TimelockController upTl = TimelockController(payable(UPGRADE_TIMELOCK));

        console.log("=== Simulating schedules (Admin Safe nonce 6, Upgrade Safe nonce 4) ===");
        executeGnosisTransactionBundle(paths[0]);
        executeGnosisTransactionBundle(paths[2]);
        require(opTl.isOperationPending(retireId) && !opTl.isOperationReady(retireId), "retire operation not pending after schedule");
        require(upTl.isOperationPending(roleId) && !upTl.isOperationReady(roleId), "role operation not pending after schedule");
        _expectRevert(ADMIN_SAFE, OPERATING_TIMELOCK, _executeData(retireTargets, retirePayloads, TL_SALT_RETIRE), "retire executeBatch succeeded before the delay");
        _expectRevert(UPGRADE_SAFE, UPGRADE_TIMELOCK, _executeData(roleTargets, rolePayloads, TL_SALT_ROLE), "role executeBatch succeeded before the delay");

        vm.warp(block.timestamp + OPERATING_DELAY + 1);
        require(opTl.isOperationReady(retireId), "retire operation not ready after 8 hours");
        require(!upTl.isOperationReady(roleId), "role operation ready after only 8 hours");
        _expectRevert(UPGRADE_SAFE, UPGRADE_TIMELOCK, _executeData(roleTargets, rolePayloads, TL_SALT_ROLE), "role executeBatch succeeded after only 8 hours");

        console.log("=== Simulating retire execute (Admin Safe nonce 7) ===");
        executeGnosisTransactionBundle(paths[1]);
        require(opTl.isOperationDone(retireId), "retire operation not done after execute");
        require(cashRegistry.hasRole(CCTP_MODULE_ADMIN_ROLE, GOVERNANCE_SAFE), "role revoked before its own delay");

        vm.warp(block.timestamp + UPGRADE_DELAY);
        require(upTl.isOperationReady(roleId), "role operation not ready after 2 days");

        // Nonce 5 is used by another transaction first; the Safe's nonce slot (5) is moved so nonce() reads 6
        require(ISafeHashes(UPGRADE_SAFE).nonce() == UPGRADE_SCHEDULE_NONCE, "Upgrade Safe nonce moved during the simulation");
        vm.store(UPGRADE_SAFE, bytes32(uint256(5)), bytes32(UPGRADE_EXECUTE_NONCE));
        require(ISafeHashes(UPGRADE_SAFE).nonce() == UPGRADE_EXECUTE_NONCE, "Upgrade Safe nonce not at the execute nonce");

        console.log("=== Simulating role revoke execute (Upgrade Safe nonce 6) ===");
        executeGnosisTransactionBundle(paths[3]);
        require(upTl.isOperationDone(roleId), "role operation not done after execute");
    }

    function _assertAfter() internal view {
        require(!dataProvider.isWhitelistedModule(OLD_MODULE), "old module still whitelisted");
        require(!dataProvider.isDefaultModule(OLD_MODULE), "old module still default");
        require(!_contains(cashModule.getWhitelistedModulesCanRequestWithdraw(), OLD_MODULE), "old module still a requester");
        require(cashRegistry.roleHolders(CCTP_MODULE_ADMIN_ROLE).length == 0, "CCTP_MODULE_ADMIN_ROLE still has a holder");

        require(!dataProvider.isWhitelistedModule(OLD_OPENOCEAN) && !dataProvider.isDefaultModule(OLD_OPENOCEAN) && !lendGateway.isDriver(OLD_OPENOCEAN), "old OpenOcean still enabled");
        require(!_contains(cashModule.getWhitelistedModulesCanRequestWithdraw(), OLD_OPENOCEAN), "old OpenOcean became a requester");
        require(dataProvider.isWhitelistedModule(NEW_OPENOCEAN) && dataProvider.isDefaultModule(NEW_OPENOCEAN) && lendGateway.isDriver(NEW_OPENOCEAN), "new OpenOcean no longer whitelisted, default and a driver");
        require(IERC20Balance(USDC).balanceOf(OLD_OPENOCEAN) == 0 && OLD_OPENOCEAN.balance == 0, "old OpenOcean holds funds");
        for (uint256 i = 0; i < DRIVER_CANDIDATES.length; ++i) {
            bool expected = DRIVER_CANDIDATES[i] == OLD_OPENOCEAN ? false : driverBefore[i];
            require(lendGateway.isDriver(DRIVER_CANDIDATES[i]) == expected, "a driver flag changed");
        }

        require(dataProvider.isWhitelistedModule(NEW_MODULE) && dataProvider.isDefaultModule(NEW_MODULE), "new module no longer whitelisted and default");
        require(_contains(cashModule.getWhitelistedModulesCanRequestWithdraw(), NEW_MODULE), "new module no longer a requester");
        CCTPModule module = CCTPModule(NEW_MODULE);
        for (uint32 d = 0; d <= MAX_DOMAIN; ++d) {
            bool expected = d == NEW_ROUTES[0] || d == NEW_ROUTES[1] || d == NEW_ROUTES[2] || d == NEW_ROUTES[3];
            require(module.isRouteAllowed(USDC, d) == expected, "new module route set changed");
        }

        address[] memory oneOld = new address[](1);
        oneOld[0] = OLD_MODULE;
        address[] memory twoOld = new address[](2);
        twoOld[0] = OLD_MODULE;
        twoOld[1] = OLD_OPENOCEAN;
        _assertRemovedOnly(whitelistedBefore, dataProvider.getWhitelistedModules(), twoOld, "whitelist");
        _assertRemovedOnly(defaultsBefore, dataProvider.getDefaultModules(), twoOld, "default set");
        _assertRemovedOnly(requestersBefore, cashModule.getWhitelistedModulesCanRequestWithdraw(), oneOld, "requesters");
        for (uint256 i = 0; i < OTHER_ROLES.length; ++i) {
            require(keccak256(abi.encode(cashRegistry.roleHolders(keccak256(bytes(OTHER_ROLES[i]))))) == otherRoleDigests[i], "a role holder list changed");
        }
        require(cashRegistry.owner() == UPGRADE_TIMELOCK, "RoleRegistry owner changed");
        console.log("whitelisted / default / requesters after:", dataProvider.getWhitelistedModules().length, dataProvider.getDefaultModules().length, cashModule.getWhitelistedModulesCanRequestWithdraw().length);
    }

    /// @dev `afterList` is `before` without the `removed` entries: shorter by that many, every other entry still present
    function _assertRemovedOnly(address[] memory before, address[] memory afterList, address[] memory removed, string memory label) internal pure {
        require(afterList.length == before.length - removed.length, string.concat(label, ": length not shorter by the removed entries"));
        for (uint256 i = 0; i < removed.length; ++i) {
            require(_contains(before, removed[i]), string.concat(label, ": removed entry was not listed before"));
            require(!_contains(afterList, removed[i]), string.concat(label, ": removed entry still listed"));
        }
        for (uint256 i = 0; i < before.length; ++i) {
            if (!_contains(removed, before[i])) require(_contains(afterList, before[i]), string.concat(label, ": another entry was removed"));
        }
    }

    function _contains(address[] memory list, address a) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }

    function _checkTimelock(address tl, uint256 minDelay) internal view {
        require(keccak256(tl.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local build");
        EtherFiTimelock t = EtherFiTimelock(payable(tl));
        require(t.getMinDelay() == minDelay, "timelock: unexpected delay");
        require(t.hasRole(t.DEFAULT_ADMIN_ROLE(), tl), "timelock is not its own admin");
    }

    function _scheduleData(address[] memory t, bytes[] memory p, uint256 minDelay, bytes32 salt_) internal pure returns (bytes memory) {
        return abi.encodeCall(TimelockController.scheduleBatch, (t, new uint256[](t.length), p, TL_PREDECESSOR, salt_, minDelay));
    }

    function _executeData(address[] memory t, bytes[] memory p, bytes32 salt_) internal pure returns (bytes memory) {
        return abi.encodeCall(TimelockController.executeBatch, (t, new uint256[](t.length), p, TL_PREDECESSOR, salt_));
    }

    /// @dev Order: admin schedule, admin execute, upgrade schedule, upgrade execute
    function _writeAndHash() internal returns (string[4] memory paths) {
        bytes memory retireSchedule = _scheduleData(retireTargets, retirePayloads, OPERATING_DELAY, TL_SALT_RETIRE);
        bytes memory retireExecute = _executeData(retireTargets, retirePayloads, TL_SALT_RETIRE);
        bytes memory roleSchedule = _scheduleData(roleTargets, rolePayloads, UPGRADE_DELAY, TL_SALT_ROLE);
        bytes memory roleExecute = _executeData(roleTargets, rolePayloads, TL_SALT_ROLE);

        paths[0] = _path("admin", ADMIN_SCHEDULE_NONCE, "schedule");
        paths[1] = _path("admin", ADMIN_EXECUTE_NONCE, "execute");
        paths[2] = _path("upgrade", UPGRADE_SCHEDULE_NONCE, "schedule");
        paths[3] = _path("upgrade", UPGRADE_EXECUTE_NONCE, "execute");
        _writeBundle(paths[0], ADMIN_SAFE, OPERATING_TIMELOCK, retireSchedule);
        _writeBundle(paths[1], ADMIN_SAFE, OPERATING_TIMELOCK, retireExecute);
        _writeBundle(paths[2], UPGRADE_SAFE, UPGRADE_TIMELOCK, roleSchedule);
        _writeBundle(paths[3], UPGRADE_SAFE, UPGRADE_TIMELOCK, roleExecute);

        _logSafeHashes("Admin Safe nonce 6 (schedule)", ADMIN_SAFE, OPERATING_TIMELOCK, retireSchedule, ADMIN_SCHEDULE_NONCE);
        _logSafeHashes("Admin Safe nonce 7 (execute)", ADMIN_SAFE, OPERATING_TIMELOCK, retireExecute, ADMIN_EXECUTE_NONCE);
        _logSafeHashes("Upgrade Safe nonce 4 (schedule)", UPGRADE_SAFE, UPGRADE_TIMELOCK, roleSchedule, UPGRADE_SCHEDULE_NONCE);
        _logSafeHashes("Upgrade Safe nonce 6 (execute)", UPGRADE_SAFE, UPGRADE_TIMELOCK, roleExecute, UPGRADE_EXECUTE_NONCE);
    }

    /// @dev Builds the hash from the Safe's domain separator and the SafeTx struct, and requires it to equal the Safe's own getTransactionHash
    function _logSafeHashes(string memory label, address safe, address to, bytes memory data, uint256 safeNonce) internal view {
        bytes32 domain = ISafeHashes(safe).domainSeparator();
        bytes32 message = keccak256(abi.encode(SAFE_TX_TYPEHASH, to, uint256(0), keccak256(data), uint8(0), uint256(0), uint256(0), uint256(0), address(0), address(0), safeNonce));
        bytes32 built = keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domain, message));
        bytes32 onchain = ISafeHashes(safe).getTransactionHash(to, 0, data, 0, 0, 0, 0, address(0), address(0), safeNonce);
        require(built == onchain, "built Safe tx hash differs from the Safe's getTransactionHash");
        console.log(label);
        console.log("  domain hash:");
        console.logBytes32(domain);
        console.log("  message hash:");
        console.logBytes32(message);
        console.log("  safe tx hash:");
        console.logBytes32(onchain);
    }

    function _path(string memory who, uint256 safeNonce, string memory kind) internal view returns (string memory) {
        return string.concat("./output/RetireOldCCTPModule-op-", vm.toString(block.chainid), "-", who, "-nonce", vm.toString(safeNonce), "-", kind, ".json");
    }

    function _writeBundle(string memory path, address safe, address to, bytes memory data) internal {
        string memory header = _getGnosisHeader(vm.toString(block.chainid), addressToHex(safe));
        vm.writeFile(path, string.concat(header, _getGnosisTransaction(addressToHex(to), iToHex(data), "0", true)));
        console.log("Wrote", path);
    }

    function _expectRevert(address from, address to, bytes memory data, string memory err) internal {
        vm.prank(from);
        (bool ok,) = to.call(data);
        require(!ok, err);
    }
}

interface ILendGatewayDrivers {
    function isDriver(address account) external view returns (bool);
    function setDriver(address driver, bool authorized) external;
}

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}
