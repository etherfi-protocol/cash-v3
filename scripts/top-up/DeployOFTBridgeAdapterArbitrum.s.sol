// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

import { CREATE3 } from "solady/utils/CREATE3.sol";

import { EtherFiOFTBridgeAdapter } from "../../src/top-up/bridge/EtherFiOFTBridgeAdapter.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title DeployOFTBridgeAdapterArbitrum
 * @notice Deploys EtherFiOFTBridgeAdapter on Arbitrum through the permissioned EtherFiDeployer
 *         (CREATE3). Arbitrum's TopUpSourceFactory currently has only a CCTPAdapter in both
 *         environments, so no OFT-bridged asset can leave the chain — which is what blocks the
 *         USDT0 top-up rail (COR-1757).
 *
 *         Ethereum and HyperEVM already run this exact adapter, unchanged; this is a deployment,
 *         not a contract change.
 *
 *         Dev and prod are separate deployments on the same chain (42161), so they take separate
 *         salts — same split as CCTPAdapter / CCTPAdapterDev. The salt namespace is deliberately
 *         chain-neutral: `EtherFiDeployer` lives at one address on every cash chain and derives
 *         the deployment address from (deployer, salt) alone, so re-running this salt on a future
 *         chain lands the adapter at the same address there.
 *
 *         Idempotent — re-running once the adapter exists skips the deploy and only re-verifies
 *         bytecode. Only registered EtherFiDeployer accounts can ever place code at these
 *         addresses, so the skip branch cannot be front-run by a squatter.
 *
 * @dev This script ONLY deploys the adapter. It does not call `TopUpFactory.setTokenConfig` and
 *      therefore changes no routing and moves no funds — wiring USDT0 to it is COR-1757, and is
 *      `onlyRoleRegistryOwner` (a 3CP bundle in prod).
 *
 * Expected addresses (CREATE3, deterministic — verified unoccupied at time of writing):
 *   mainnet: 0x406593Aafa613ac16382667d06D54a2Fd16DF48c
 *   dev:     0x8E8B709339715A87dFE50EdF60E6290254cBdCD9
 *
 * Usage — drop --broadcast to simulate; the broadcasting account must be in the EtherFiDeployer
 * registry, and --sender must match so simulation and broadcast agree on the account:
 *   source .env && ENV=mainnet forge script scripts/top-up/DeployOFTBridgeAdapterArbitrum.s.sol:DeployOFTBridgeAdapterArbitrum \
 *     --rpc-url $ARBITRUM_RPC --ledger --sender $PROD_DEPLOYER \
 *     --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvvv
 */
contract DeployOFTBridgeAdapterArbitrum is Utils {
    /// @dev Permissioned CREATE3 deployer — same address on every cash chain.
    address internal constant ETHERFI_DEPLOYER = 0xFCD957b5913d607BF2222280093421B1e2Af6f30;

    string internal constant DEPLOYER_RECORD_PATH = "/deployments/deployer/etherfi-deployer.json";

    /// @dev Namespace for this salt family. Bump only to intentionally move to a fresh address.
    string internal constant SALT_PREFIX = "TopUpBridgeAdapters.";

    string internal constant ADAPTER_NAME = "EtherFiOFTBridgeAdapter";
    string internal constant ADAPTER_NAME_DEV = "EtherFiOFTBridgeAdapterDev";

    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;

    function run() public {
        require(block.chainid == ARBITRUM_CHAIN_ID, "DeployOFTBridgeAdapterArbitrum: Arbitrum only");

        // getEnv() already rejects anything other than "mainnet" / "dev".
        bool isDev = isEqualString(getEnv(), "dev");
        string memory name = isDev ? ADAPTER_NAME_DEV : ADAPTER_NAME;

        _requireDeployer(msg.sender);

        // Sanity: the environment's TopUpSourceFactory must exist, so a wrong ENV is caught here
        // rather than by an adapter that lands in the wrong deployment record.
        address topUpFactory = stdJson.readAddress(readDeploymentFile(), ".addresses.TopUpSourceFactory");
        require(topUpFactory.code.length != 0, "TopUpSourceFactory has no code on this chain/env");

        address predicted = _predicted(name);

        console.log("=== Deploy EtherFiOFTBridgeAdapter (Arbitrum) ===");
        console.log("Env:               ", getEnv());
        console.log("Salt name:         ", string.concat(SALT_PREFIX, name));
        console.log("TopUpSourceFactory:", topUpFactory);
        console.log("Predicted adapter: ", predicted);

        address adapter = predicted;
        if (predicted.code.length > 0) {
            console.log("  [SKIP] already deployed at", predicted);
        } else {
            vm.startBroadcast();
            // msg.sender outside the broadcast context is foundry's default script sender unless
            // --sender is passed; read the account that will actually sign.
            (, address broadcaster,) = vm.readCallers();
            _requireDeployer(broadcaster);
            adapter = EtherFiDeployer(ETHERFI_DEPLOYER).deploy(_salt(name), type(EtherFiOFTBridgeAdapter).creationCode);
            vm.stopBroadcast();
        }

        require(adapter == predicted, "deployed address != predicted");

        // EtherFiOFTBridgeAdapter has no constructor and no immutables, so runtimeCode is the exact
        // expected code. Matching it proves the address holds this repo's build, whoever deployed it.
        require(
            keccak256(adapter.code) == keccak256(type(EtherFiOFTBridgeAdapter).runtimeCode),
            "deployed bytecode != local EtherFiOFTBridgeAdapter build"
        );

        // The adapter must not already be wired into any routing — that is COR-1757's job.
        require(!TopUpFactory(payable(topUpFactory)).isTokenSupported(adapter), "adapter unexpectedly registered as a token");

        _writeDeploymentRecord(adapter);

        console.log("  [OK] EtherFiOFTBridgeAdapter:", adapter);
    }

    /// @dev Fails before any broadcast if the deployer isn't the recorded one, isn't live on this
    ///      chain, or hasn't authorised `broadcaster`.
    function _requireDeployer(address broadcaster) internal view {
        address recorded = stdJson.readAddress(vm.readFile(string.concat(vm.projectRoot(), DEPLOYER_RECORD_PATH)), ".EtherFiDeployer");
        require(recorded == ETHERFI_DEPLOYER, "ETHERFI_DEPLOYER does not match deployments/deployer/etherfi-deployer.json");
        require(ETHERFI_DEPLOYER.code.length != 0, "EtherFiDeployer not deployed on this chain");
        require(
            EtherFiDeployer(ETHERFI_DEPLOYER).isDeployer(broadcaster),
            "broadcaster is not a registered EtherFiDeployer deployer; owner must call configureDeployers first"
        );
    }

    function _salt(string memory name) internal pure returns (bytes32) {
        return keccak256(bytes(string.concat(SALT_PREFIX, name)));
    }

    /// @dev The address `EtherFiDeployer.deploy(_salt(name), ...)` produces.
    function _predicted(string memory name) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(_salt(name), ETHERFI_DEPLOYER);
    }

    /// @dev Keyed write, so the rest of the environment's deployment record is preserved.
    function _writeDeploymentRecord(address adapter) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && !vm.isContext(VmSafe.ForgeContext.ScriptResume)) {
            console.log("Dry run, not writing deployment record");
            return;
        }
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/deployments.json");
        vm.writeJson(string.concat("\"", vm.toString(adapter), "\""), path, ".addresses.EtherFiOFTBridgeAdapter");
        console.log("Deployment record updated:", path);
    }
}
