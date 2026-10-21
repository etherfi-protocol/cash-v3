// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { ILayerZeroTeller } from "../../src/interfaces/ILayerZeroTeller.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiTimelock } from "../../src/timelock/EtherFiTimelock.sol";
import { EtherFiLiquidBridgeAdapter } from "../../src/top-up/bridge/EtherFiLiquidBridgeAdapter.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { SEthFiTopUpConfig } from "./SEthFiTopUpConfig.sol";

/// @title SEthFiTopUp3CP
/// @notice Generates and fork-simulates the 3CP bundles that open sETHFI top-ups from Arbitrum and Base.
///         It contains no broadcast call: it writes Safe Transaction Builder JSONs to ./output and simulates
///         them with prank.
///
///         One timelock operation per chain, signed by the operating Safe 0xA6cf...AAC4 (proposer and executor
///         on the 8h operating timelock 0x9AEb...7849, the only ADMIN_TIMELOCK_ROLE holder):
///           Arbitrum  nonce 24  operatingTimelock.scheduleBatch
///                     nonce 25  operatingTimelock.executeBatch (not before 8 hours after nonce 24 executes)
///           Base      nonce 33  operatingTimelock.scheduleBatch
///                     nonce 34  operatingTimelock.executeBatch (not before 8 hours after nonce 33 executes)
///         Each batch is one call:
///           TopUpFactory.setTokenConfig([sETHFI], [10], [{liquid adapter, Ethereum TopUpFactory, 50, (teller, 30101)}])
///
///         Prerequisite on Arbitrum: DeploySEthFiTopUpAdapterArbitrum. If it has not run yet, the adapter is
///         deployed on the fork only so the bundle can still be simulated; the real deploy must land before
///         signing.
///
/// Usage (no broadcast):
///   ENV=mainnet forge script scripts/sethfi-topup/SEthFiTopUp3CP.s.sol --rpc-url $ARBITRUM_RPC
///   ENV=mainnet forge script scripts/sethfi-topup/SEthFiTopUp3CP.s.sol --rpc-url $BASE_RPC
contract SEthFiTopUp3CP is SEthFiTopUpConfig, GnosisHelpers, ContractCodeChecker, StdCheats {
    using stdJson for string;

    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant OPERATING_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    uint256 internal constant OPERATING_DELAY = 8 hours;

    uint256 internal constant ARB_SCHEDULE_NONCE = 24;
    uint256 internal constant ARB_EXECUTE_NONCE = 25;
    uint256 internal constant BASE_SCHEDULE_NONCE = 33;
    uint256 internal constant BASE_EXECUTE_NONCE = 34;

    bytes32 internal constant TL_PREDECESSOR = bytes32(0);

    TopUpFactory internal factory;
    RoleRegistry internal roleRegistry;
    address internal adapter;
    TopUpFactory.TokenConfig internal config;
    address[] internal targets;
    bytes[] internal payloads;

    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "prod only: ENV must be mainnet");
        console.log("Fork block:", block.number);

        _loadAndPreflight();

        targets.push(address(factory));
        payloads.push(abi.encodeCall(TopUpFactory.setTokenConfig, (_asArray(SETHFI), _asArray(OP_CHAIN_ID), _asArray(config))));

        bytes32 salt = _salt();
        TimelockController tl = TimelockController(payable(OPERATING_TIMELOCK));
        bytes32 id = tl.hashOperationBatch(targets, new uint256[](1), payloads, TL_PREDECESSOR, salt);
        require(!tl.isOperation(id), "operation already scheduled");

        (uint256 scheduleNonce, uint256 executeNonce) = _nonces();
        require(_safeNonce() <= scheduleNonce, "Safe nonce is past the schedule nonce: update the pinned nonces");
        string memory chain = _chainName();
        string memory prefix = string.concat("./output/sethfi-topup-", chain, "-");
        string memory schedulePath = string.concat(prefix, vm.toString(scheduleNonce), "-schedule-sethfi-topup-config.json");
        string memory executePath = string.concat(prefix, vm.toString(executeNonce), "-execute-sethfi-topup-config.json");
        vm.createDir("./output", true);
        _writeBundle(schedulePath, _scheduleData(salt));
        _writeBundle(executePath, _executeData(salt));

        _simulate(id, schedulePath, executePath);
        _assertConfigStored();
        _simulateBridge();

        console.log("");
        console.log("  [OK] sETHFI top-up rail wired on", chain);
        console.log("  adapter:  ", adapter);
        console.log("  recipient:", config.recipientOnDestChain);
        console.log("8h operation id:");
        console.logBytes32(id);
    }

    /// @dev Fails before writing anything if the live state is not what the batch assumes
    function _loadAndPreflight() internal {
        string memory dep = readDeploymentFile();
        factory = TopUpFactory(payable(dep.readAddress(".addresses.TopUpSourceFactory")));
        roleRegistry = RoleRegistry(dep.readAddress(".addresses.RoleRegistry"));

        // Governance: setTokenConfig is onlyAdminTimelock and only the operating timelock holds that role
        _checkTimelock();
        address[] memory atl = roleRegistry.roleHolders(roleRegistry.ADMIN_TIMELOCK_ROLE());
        require(atl.length == 1 && atl[0] == OPERATING_TIMELOCK, "ADMIN_TIMELOCK_ROLE is not held by exactly the operating timelock");
        EtherFiTimelock tl = EtherFiTimelock(payable(OPERATING_TIMELOCK));
        require(tl.hasRole(tl.PROPOSER_ROLE(), OPERATING_SAFE) && tl.hasRole(tl.EXECUTOR_ROLE(), OPERATING_SAFE), "operating Safe is not proposer and executor");

        // Teller: only the Ethereum peer is set, which is why the route goes through Ethereum
        require(address(ILayerZeroTeller(SETHFI_TELLER).vault()) == SETHFI, "teller vault is not sETHFI");
        require(_peer(ETHEREUM_EID) == bytes32(uint256(uint160(SETHFI_TELLER))), "teller has no Ethereum peer");

        adapter = _adapterFor(block.chainid);
        if (block.chainid == ARBITRUM) _ensureArbitrumAdapter();
        else require(dep.readAddress(".addresses.EtherFiLiquidBridgeAdapter") == adapter, "Base adapter differs from the deployment manifest");
        requireExactCodeMatch("EtherFiLiquidBridgeAdapter", adapter, address(new EtherFiLiquidBridgeAdapter()));

        config = _sEthFiTokenConfig(adapter);
        require(config.recipientOnDestChain == address(factory), "Ethereum TopUpFactory is not at the local factory address");
        require(!factory.isTokenSupported(SETHFI), "sETHFI already has a top-up config on this chain");
    }

    /// @dev Deploys the adapter on the fork when the real deploy has not happened yet
    function _ensureArbitrumAdapter() internal {
        require(_predictAddress(ARB_ADAPTER_SALT) == ARB_LIQUID_ADAPTER, "adapter salt does not resolve to the pinned address");
        if (ARB_LIQUID_ADAPTER.code.length == 0) {
            console.log("WARNING: Arbitrum EtherFiLiquidBridgeAdapter not deployed on-chain yet; deploying on the fork only");
            vm.prank(DEPLOYER.getDeployers()[0]);
            DEPLOYER.deploy(getSalt(ARB_ADAPTER_SALT), type(EtherFiLiquidBridgeAdapter).creationCode);
        }
    }

    function _simulate(bytes32 id, string memory schedulePath, string memory executePath) internal {
        TimelockController tl = TimelockController(payable(OPERATING_TIMELOCK));

        _expectRevert(OPERATING_SAFE, address(factory), payloads[0], "operating Safe set the token config directly");

        console.log("=== Simulating schedule ===");
        executeGnosisTransactionBundle(schedulePath);
        require(tl.isOperationPending(id) && !tl.isOperationReady(id), "operation not pending after schedule");
        _expectRevert(OPERATING_SAFE, OPERATING_TIMELOCK, _executeData(_salt()), "executeBatch succeeded before the delay");

        vm.warp(block.timestamp + OPERATING_DELAY + 1);
        require(tl.isOperationReady(id), "operation not ready after 8 hours");

        console.log("=== Simulating execute ===");
        executeGnosisTransactionBundle(executePath);
        require(tl.isOperationDone(id), "operation not done after execute");
    }

    function _assertConfigStored() internal view {
        TopUpFactory.TokenConfig memory stored = factory.getTokenConfig(SETHFI, OP_CHAIN_ID);
        require(stored.bridgeAdapter == config.bridgeAdapter, "bridgeAdapter mismatch");
        require(stored.recipientOnDestChain == config.recipientOnDestChain, "recipientOnDestChain mismatch");
        require(stored.maxSlippageInBps == config.maxSlippageInBps, "maxSlippageInBps mismatch");
        require(keccak256(stored.additionalData) == keccak256(config.additionalData), "additionalData mismatch");
        require(factory.isTokenSupportedOnChain(SETHFI, OP_CHAIN_ID), "sETHFI not supported for chain 10");
    }

    /// @dev Real teller send on the fork, through a live bridger: proves the route quotes and executes
    function _simulateBridge() internal {
        uint256 amount = 1 ether;
        uint256 before = IERC20(SETHFI).balanceOf(address(factory));
        deal(SETHFI, address(factory), before + amount);

        address bridger = roleRegistry.roleHolders(factory.TOPUP_FACTORY_BRIDGER_ROLE())[0];
        (, uint256 fee) = factory.getBridgeFee(SETHFI, amount, OP_CHAIN_ID);
        require(fee > 0, "teller quoted a zero fee");
        vm.deal(bridger, fee);

        vm.prank(bridger);
        factory.bridge{ value: fee }(SETHFI, amount, OP_CHAIN_ID);
        require(IERC20(SETHFI).balanceOf(address(factory)) == before, "sETHFI not consumed by the bridge");
        console.log("Simulated bridge of 1 sETHFI to the Ethereum TopUpFactory, native fee (wei):", fee);
    }

    // ---- helpers ----

    function _checkTimelock() internal view {
        require(keccak256(OPERATING_TIMELOCK.code) == keccak256(type(EtherFiTimelock).runtimeCode), "timelock bytecode != local build");
        EtherFiTimelock tl = EtherFiTimelock(payable(OPERATING_TIMELOCK));
        require(tl.getMinDelay() == OPERATING_DELAY, "timelock: unexpected delay");
        require(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), OPERATING_TIMELOCK), "timelock is not its own admin");
    }

    function _peer(uint32 eid) internal view returns (bytes32 peer) {
        (bool ok, bytes memory ret) = SETHFI_TELLER.staticcall(abi.encodeWithSignature("peers(uint32)", eid));
        require(ok, "teller peers() call failed");
        peer = abi.decode(ret, (bytes32));
    }

    function _safeNonce() internal view returns (uint256) {
        (bool ok, bytes memory ret) = OPERATING_SAFE.staticcall(abi.encodeWithSignature("nonce()"));
        require(ok, "Safe nonce() call failed");
        return abi.decode(ret, (uint256));
    }

    function _nonces() internal view returns (uint256, uint256) {
        if (block.chainid == ARBITRUM) return (ARB_SCHEDULE_NONCE, ARB_EXECUTE_NONCE);
        return (BASE_SCHEDULE_NONCE, BASE_EXECUTE_NONCE);
    }

    function _chainName() internal view returns (string memory) {
        return block.chainid == ARBITRUM ? "arbitrum" : "base";
    }

    function _salt() internal view returns (bytes32) {
        return keccak256(bytes(string.concat("SEthFiTopUp.", _chainName(), ".SetTokenConfig.v1")));
    }

    function _scheduleData(bytes32 salt) internal view returns (bytes memory) {
        return abi.encodeCall(TimelockController.scheduleBatch, (targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt, OPERATING_DELAY));
    }

    function _executeData(bytes32 salt) internal view returns (bytes memory) {
        return abi.encodeCall(TimelockController.executeBatch, (targets, new uint256[](targets.length), payloads, TL_PREDECESSOR, salt));
    }

    function _writeBundle(string memory path, bytes memory data) internal {
        string memory header = _getGnosisHeader(vm.toString(block.chainid), addressToHex(OPERATING_SAFE));
        vm.writeFile(path, string.concat(header, _getGnosisTransaction(addressToHex(OPERATING_TIMELOCK), iToHex(data), "0", true)));
        console.log("Wrote", path);
    }

    function _expectRevert(address from, address to, bytes memory data, string memory err) internal {
        vm.prank(from);
        (bool ok,) = to.call(data);
        require(!ok, err);
    }

    function _asArray(address value) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = value;
    }

    function _asArray(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    function _asArray(TopUpFactory.TokenConfig memory value) internal pure returns (TopUpFactory.TokenConfig[] memory arr) {
        arr = new TopUpFactory.TokenConfig[](1);
        arr[0] = value;
    }
}
