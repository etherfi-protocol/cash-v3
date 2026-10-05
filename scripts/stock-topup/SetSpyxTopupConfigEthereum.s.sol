// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { Test } from "forge-std/Test.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { StockTopupConfig } from "./StockTopupConfig.sol";

/**
 * @title SetSpyxTopupConfigEthereum
 * @notice Wires SPYx on the Ethereum TopUpSourceFactory: `setTokenConfig(SPYx, 10, cfg)`
 *         with `cfg.bridgeAdapter = StockOFTBridgeAdapter`, `cfg.recipientOnDestChain =
 *         TopUpDest (Optimism)` and `cfg.additionalData = (wSPYx OFTAdapter, OP eid,
 *         lzReceive gas)`. After this, a SPYx topup is wrapped into wSPYx and OFT-sent to
 *         the OP TopUpDest, where it arrives as iwSPYx.
 *
 *         Two-actor flow, selected by ENV:
 *         - ENV=dev:     the broadcaster owns the RoleRegistry — the call is broadcast directly.
 *         - ENV=mainnet: `setTokenConfig` is `onlyRoleRegistryOwner` (the prod operating
 *                        Safe), so the call is written as a Gnosis bundle to
 *                        output/SetSpyxTopupConfigEthereum-1.json for the Safe to execute.
 *
 *         Either way the script then simulates the resulting state on the fork and asserts
 *         it end to end: the stored config matches, and a real SPYx bridge quotes and
 *         executes through the live wSPYx OFTAdapter.
 *
 * Env: ENV (dev|mainnet), PRIVATE_KEY (dev only)
 *
 * Run:
 *   ENV=mainnet forge script scripts/stock-topup/SetSpyxTopupConfigEthereum.s.sol --rpc-url $MAINNET_RPC
 *   ENV=dev PRIVATE_KEY=0x... forge script scripts/stock-topup/SetSpyxTopupConfigEthereum.s.sol \
 *     --rpc-url $MAINNET_RPC --broadcast
 */
contract SetSpyxTopupConfigEthereum is StockTopupConfig, GnosisHelpers, Test {
    using stdJson for string;

    string internal constant OUTPUT_PATH = "./output/SetSpyxTopupConfigEthereum-1.json";

    /// @dev Wei of SPYx the shares-rounding of a fund + wrap round trip may leave behind.
    uint256 internal constant SHARES_ROUNDING_DUST = 2;

    TopUpFactory internal factory;
    RoleRegistry internal roleRegistry;
    address internal adapter;
    address internal recipient;

    function run() public {
        require(block.chainid == 1, "This script must be run on Ethereum mainnet (chain ID 1)");

        _loadAndPreflight();

        TopUpFactory.TokenConfig memory config = _spyxTokenConfig(adapter, recipient);
        bytes memory callData = abi.encodeCall(TopUpFactory.setTokenConfig, (_asArray(SPYX), _asArray(OP_CHAIN_ID), _asArray(config)));

        address owner = roleRegistry.owner();

        if (_isDev()) {
            uint256 deployerPk = vm.envUint("PRIVATE_KEY");
            require(vm.addr(deployerPk) == owner, "dev: broadcaster does not own the RoleRegistry");

            vm.startBroadcast(deployerPk);
            (bool ok,) = address(factory).call(callData);
            require(ok, "setTokenConfig failed");
            vm.stopBroadcast();
        } else {
            require(owner == SAFE, "prod: RoleRegistry owner is not the operating Safe - timelock path not implemented");

            string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
            txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(factory)), iToHex(callData), "0", true));

            vm.createDir("./output", true);
            vm.writeFile(OUTPUT_PATH, txs);
            console.log("Gnosis bundle written to:", OUTPUT_PATH);

            executeGnosisTransactionBundle(OUTPUT_PATH);
        }

        _assertConfigStored(config);
        _simulateBridge();

        console.log("ENV:", getEnv());
        console.log("SPYx -> Optimism topup wired. adapter: %s, recipient: %s", adapter, recipient);
    }

    /// @dev Loads the live addresses and fails before writing anything if the rail is not sane.
    function _loadAndPreflight() internal {
        _assertAssetWiring();

        string memory deployments = vm.readFile(_ethereumDeploymentPath());
        factory = TopUpFactory(payable(deployments.readAddress(".addresses.TopUpSourceFactory")));
        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));

        // Prefer the recorded adapter, fall back to the deterministic address, and require
        // the two agree — a recorded address off the CREATE3 slot means a hijacked manifest.
        adapter = _adapterAddress();
        if (vm.keyExistsJson(deployments, string.concat(".addresses.", ADAPTER_DEPLOYMENT_KEY))) {
            require(deployments.readAddress(string.concat(".addresses.", ADAPTER_DEPLOYMENT_KEY)) == adapter, "recorded StockOFTBridgeAdapter != predicted CREATE3 address");
        }
        require(adapter.code.length > 0, "StockOFTBridgeAdapter not deployed - run DeployStockOFTBridgeAdapter first");

        recipient = _topUpDestOptimism();
        require(recipient != address(0), "TopUpDest on Optimism not found");

        // The wSPYx rail is a lock/mint OFT: nothing else on this factory may already claim
        // (SPYx, chain 10) with a different adapter without us noticing.
        TopUpFactory.TokenConfig memory existing = factory.getTokenConfig(SPYX, OP_CHAIN_ID);
        if (existing.bridgeAdapter != address(0)) console.log("NOTE: overwriting existing SPYx config, adapter was:", existing.bridgeAdapter);
    }

    /// @dev Post-state: every field of the stored config, read back from the factory.
    function _assertConfigStored(TopUpFactory.TokenConfig memory expected) internal view {
        TopUpFactory.TokenConfig memory stored = factory.getTokenConfig(SPYX, OP_CHAIN_ID);
        assertEq(stored.bridgeAdapter, expected.bridgeAdapter, "bridgeAdapter mismatch");
        assertEq(stored.recipientOnDestChain, expected.recipientOnDestChain, "recipientOnDestChain mismatch");
        assertEq(uint256(stored.maxSlippageInBps), uint256(expected.maxSlippageInBps), "maxSlippageInBps mismatch");
        assertEq(stored.additionalData, expected.additionalData, "additionalData mismatch");
    }

    /**
     * @dev End-to-end fork simulation of a real topup: fund the factory with SPYx, quote the
     *      bridge fee through the live OFTAdapter and execute the wrap + send. This is what
     *      catches an lzReceive gas or slippage value the executor/OFT rejects — a config
     *      that stores fine but cannot be quoted.
     *
     *      `deal` cannot locate SPYx's balance slot (rebasing, shares-based à la stETH), so
     *      the funding comes from the wrapper vault, the largest holder we know exists.
     */
    function _simulateBridge() internal {
        uint256 amount = 10 ** IERC20Metadata(SPYX).decimals();
        require(IERC20(SPYX).balanceOf(WSPYX) >= amount, "wrapper vault holds too little SPYx to simulate");

        uint256 balanceBefore = IERC20(SPYX).balanceOf(address(factory));
        vm.prank(WSPYX);
        IERC20(SPYX).transfer(address(factory), amount);
        // Shares rounding can credit a wei or two less than `amount`; bridge what arrived.
        uint256 bridgeAmount = IERC20(SPYX).balanceOf(address(factory)) - balanceBefore;

        address bridger = makeAddr("stockTopupBridger");
        // Read both through locals: a call in the argument list would be evaluated after
        // `vm.prank` arms and would consume the prank, leaving `grantRole` unauthorized.
        address registryOwner = roleRegistry.owner();
        bytes32 bridgerRole = factory.TOPUP_FACTORY_BRIDGER_ROLE();
        vm.prank(registryOwner);
        roleRegistry.grantRole(bridgerRole, bridger);

        (, uint256 fee) = factory.getBridgeFee(SPYX, bridgeAmount, OP_CHAIN_ID);
        vm.deal(bridger, fee);

        vm.prank(bridger);
        factory.bridge{ value: fee }(SPYX, bridgeAmount, OP_CHAIN_ID);

        // SPYx is a rebasing, shares-based token: every transfer and the wrapper deposit
        // convert through shares and round down, so a wei or two of the funded amount can
        // survive the wrap. Assert the bridge consumed the funding, not that it left zero.
        assertApproxEqAbs(IERC20(SPYX).balanceOf(address(factory)), balanceBefore, SHARES_ROUNDING_DUST, "SPYx not consumed by the bridge");
        console.log("Simulated bridge of %s SPYx wei, native fee %s wei", bridgeAmount, fee);
    }

    // ---- single-element array helpers (setTokenConfig is batch-shaped) ----

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
