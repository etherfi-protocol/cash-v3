// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { StargateAdapter } from "../../src/top-up/bridge/StargateAdapter.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/**
 * @title DeployStargateTaxiBase
 * @notice Deploys the Base taxi adapter and updates only the existing WETH routes.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/stargate-taxi/DeployBase.s.sol \
 *     --rpc-url $BASE_RPC --broadcast --verify
 */
contract DeployStargateTaxiBase is EtherFiDeployerHelper, GnosisHelpers, ContractCodeChecker {
    using stdJson for string;

    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant OLD_STARGATE_ADAPTER = 0x51dD76A7081c7b84e410A77968a72EEeE1Caf4C3;
    address internal constant EXPECTED_ADAPTER = 0xbef9e4242A33A652ffC0995585884e017Ba6Fa54;
    address internal constant DESTINATION_RECIPIENT = 0x3a6A724595184dda4be69dB1Ce726F2Ac3D66B87;
    address internal constant STARGATE_POOL = 0xdc181Bd607330aeeBEF6ea62e03e5e1Fb4B6F7C7;
    uint32 internal constant SCROLL_EID = 30_214;
    uint32 internal constant OPTIMISM_EID = 30_111;
    uint96 internal constant MAX_SLIPPAGE_BPS = 50;
    string internal constant ADAPTER_SALT = "Prod.StargateTaxi.Base.StargateAdapter";

    TopUpFactory internal factory;
    RoleRegistry internal roleRegistry;
    address internal adapter;

    /// @notice Deploys the adapter, writes the Safe bundle, and simulates both route updates.
    function run() public {
        require(block.chainid == 8453, "Base only");
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");

        _loadAndCheckExistingDeployment();
        _deploy();
        string memory bundle = _writeRouteSwitchBundle();
        _simulate(bundle);

        console.log("Record StargateAdapter in deployments/mainnet/8453/deployments.json:", adapter);
    }

    /// @dev Loads the factory and rejects any route or owner change outside this rollout.
    function _loadAndCheckExistingDeployment() internal {
        string memory deployments = readDeploymentFile();
        factory = TopUpFactory(payable(deployments.readAddress(".addresses.TopUpSourceFactory")));
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        require(deployments.readAddress(".addresses.StargateAdapter") == OLD_STARGATE_ADAPTER, "unexpected old StargateAdapter");
        require(roleRegistry.owner() == SAFE, "Safe is not RoleRegistry owner");

        _checkRoute(factory.getTokenConfig(WETH, 534_352), OLD_STARGATE_ADAPTER, SCROLL_EID);
        _checkRoute(factory.getTokenConfig(WETH, 10), OLD_STARGATE_ADAPTER, OPTIMISM_EID);
    }

    /// @dev Deploys the adapter through the permissioned EtherFi CREATE3 deployer.
    function _deploy() internal {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);
        require(address(DEPLOYER).code.length > 0, "EtherFiDeployer is not deployed");
        require(DEPLOYER.isDeployer(broadcaster), "broadcaster is not an approved deployer");

        vm.startBroadcast(privateKey);
        adapter = _create3(ADAPTER_SALT, type(StargateAdapter).creationCode, abi.encode(WETH));
        vm.stopBroadcast();

        require(_predictAddress(ADAPTER_SALT) == EXPECTED_ADAPTER && adapter == EXPECTED_ADAPTER, "adapter address mismatch");
        require(StargateAdapter(payable(adapter)).weth() == WETH, "adapter WETH mismatch");
        requireExactCodeMatch("StargateAdapter", adapter, address(new StargateAdapter(WETH)));
    }

    /// @dev Copies both live route configs and changes only their adapter address.
    function _writeRouteSwitchBundle() internal returns (string memory path) {
        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = WETH;
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 534_352;
        chainIds[1] = 10;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](2);
        configs[0] = _routeConfig(adapter, SCROLL_EID);
        configs[1] = _routeConfig(adapter, OPTIMISM_EID);

        bytes memory data = abi.encodeCall(TopUpFactory.setTokenConfig, (tokens, chainIds, configs));
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(factory)), iToHex(data), "0", true));

        path = "./output/StargateTaxi-Base-route-switch.json";
        vm.createDir("./output", true);
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    /// @dev Simulates the bundle and confirms that both existing routes use the new adapter.
    function _simulate(string memory bundle) internal {
        executeGnosisTransactionBundle(bundle);
        _checkRoute(factory.getTokenConfig(WETH, 534_352), adapter, SCROLL_EID);
        _checkRoute(factory.getTokenConfig(WETH, 10), adapter, OPTIMISM_EID);
        console.log("Stargate taxi Base bundle simulation passed");
    }

    /// @dev Returns one pinned WETH route with only the adapter supplied by the caller.
    function _routeConfig(address bridgeAdapter, uint32 destinationEid) internal pure returns (TopUpFactory.TokenConfig memory) {
        return TopUpFactory.TokenConfig({ bridgeAdapter: bridgeAdapter, recipientOnDestChain: DESTINATION_RECIPIENT, maxSlippageInBps: MAX_SLIPPAGE_BPS, additionalData: abi.encode(STARGATE_POOL, destinationEid) });
    }

    /// @dev Checks every mutable route field before generation and after simulation.
    function _checkRoute(TopUpFactory.TokenConfig memory actual, address bridgeAdapter, uint32 destinationEid) internal pure {
        TopUpFactory.TokenConfig memory expected = _routeConfig(bridgeAdapter, destinationEid);
        require(actual.bridgeAdapter == expected.bridgeAdapter, "route adapter mismatch");
        require(actual.recipientOnDestChain == expected.recipientOnDestChain, "route recipient mismatch");
        require(actual.maxSlippageInBps == expected.maxSlippageInBps, "route slippage mismatch");
        require(keccak256(actual.additionalData) == keccak256(expected.additionalData), "route data mismatch");
    }
}
