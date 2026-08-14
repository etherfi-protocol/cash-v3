// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";
import { StdCheats } from "forge-std/StdCheats.sol";

import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { StockTopupConfig } from "../stock-topup/StockTopupConfig.sol";
import { StockWithdrawConfig } from "../stock-withdraw/StockWithdrawConfig.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";

/**
 * @title ConfigureStockRailEth3CP
 * @author ether.fi
 * @notice 3CP-647 — the ENTIRE Ethereum leg of the xStock rollout, in ONE bundle:
 *
 *           1. RoleRegistry.grantRole(STOCK_UNWRAPPER_ADMIN_ROLE, SAFE)
 *           2. TopUpFactory.setTokenConfig([SPYx, QQQx, TBLLx], [10, 10, 10], [cfg, cfg, cfg])
 *
 *         Call 1 gives the Safe admin control of the `StockUnwrapper`, the destination half of
 *         the withdrawal rail (OP -> Ethereum). Call 2 opens the top-up rail in the other
 *         direction (Ethereum -> OP): raw Backed stock deposited into a TopUp gets wrapped into
 *         its ERC-4626 wrapper and OFT-sent to the OP `TopUpDest`, arriving as the already-listed
 *         iTOKEN.
 *
 * @dev WHY ONE BUNDLE AND NO TIMELOCK. Both calls are owner-gated (`grantRole` is `onlyOwner`;
 *      `setTokenConfig` is `onlyRoleRegistryOwner`) and on Ethereum that owner is the
 *      OperatingSafe ITSELF — the handover that put the OP registry behind the 8h
 *      `EtherFiTimelock` has no Ethereum counterpart. So both are plain Safe transactions with
 *      the same authority and the same signers, and splitting them would only cost an extra
 *      signing round. `_assertGovernance` proves the premise on-chain instead of assuming it: if
 *      Ethereum is ever handed over, this script refuses to emit a bundle whose transactions
 *      would revert.
 *
 *      The OP side is different and stays separate: 3CP-646 enables the module (role-gated, no
 *      timelock) and 3CP-648 grants the module admin role through the timelock.
 *
 * @dev WHAT IS AND IS NOT LAUNCH-BLOCKING HERE:
 *        - the unwrapper's whole config is set at `initialize` and `pause()` is PAUSER-gated
 *          (the Safe holds it), so withdrawals already work without call 1. The role buys
 *          `configureAdapters`, `setSrcModule` and the break-glass `rescueTokens` — the last of
 *          which is the only exit for a compose message that can never settle on either branch;
 *        - call 2 IS the top-up feature: with no token config a raw-stock deposit cannot be
 *          bridged at all.
 *
 * @dev THE TWO TOP-UP PARAMETERS THAT LOOK COSMETIC AND ARE NOT:
 *        - `maxSlippageInBps` MUST be nonzero. It applies to the WRAPPED SHARES and its real job
 *          is absorbing the OFT's shared-decimals dust truncation; at 0 bps the route cannot even
 *          be QUOTED (`SlippageExceeded` inside `quoteSend`).
 *        - `lzReceiveGas` MUST be present. Backed OFTs carry no enforced SEND options, so empty
 *          options make the executor fee library revert `Executor_NoOptions`.
 *      Both fail at quote time rather than in storage, so the simulation ends on a live
 *      `getBridgeFee` per asset — a nonzero quote is the only evidence either is right.
 *
 * Prerequisites (both recorded in deployments/mainnet/1/deployments.json):
 *   - StockUnwrapper deployed  (scripts/stock-withdraw/DeployStockUnwrapper.s.sol, ENV=mainnet)
 *   - StockOFTBridgeAdapter deployed (scripts/stock-topup/DeployStockOFTBridgeAdapter.s.sol)
 *   - bytecode gates green: VerifyStockWithdrawBytecode.s.sol + VerifyStockTopupBytecode.s.sol
 *
 * Usage (no broadcast — writes ./output/*.json and simulates):
 *   forge script scripts/gnosis-txs/ConfigureStockRailEth3CP.s.sol --rpc-url $MAINNET_RPC
 *
 * Optional deeper simulation (funds the factory on the fork and performs a real wrap + OFT send):
 *   SIMULATE_BRIDGE=true forge script scripts/gnosis-txs/ConfigureStockRailEth3CP.s.sol --rpc-url $MAINNET_RPC
 */
contract ConfigureStockRailEth3CP is StockWithdrawConfig, StockTopupConfig, GnosisHelpers, StdCheats {
    using stdJson for string;

    /// @dev UpgradeableProxy ERC-7201 slot; first member is the roleRegistry address.
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    RoleRegistry internal roleRegistry;
    StockUnwrapper internal unwrapper;
    TopUpFactory internal factory;
    bytes32 internal adminRole;
    address internal bridgeAdapter;
    address internal recipient;

    function run() public {
        require(block.chainid == 1, "ConfigureStockRailEth: Ethereum mainnet only");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        _loadAddresses();
        _checkPreconditions();

        string memory path = _writeBundle();
        _simulateAndVerify(path);
    }

    // ── Address loading ───────────────────────────────────────────────────────────

    function _loadAddresses() internal {
        string memory deployments = readDeploymentFile();

        require(
            vm.keyExistsJson(deployments, ".addresses.StockUnwrapper"),
            "StockUnwrapper missing from deployments.json - deploy it first (DeployStockUnwrapper.s.sol, ENV=mainnet)"
        );

        roleRegistry = RoleRegistry(deployments.readAddress(".addresses.RoleRegistry"));
        unwrapper = StockUnwrapper(deployments.readAddress(".addresses.StockUnwrapper"));
        factory = TopUpFactory(payable(deployments.readAddress(".addresses.TopUpSourceFactory")));
        adminRole = unwrapper.STOCK_UNWRAPPER_ADMIN_ROLE();
        bridgeAdapter = _adapterAddress();
        recipient = _topUpDestOptimism();

        if (vm.keyExistsJson(deployments, string.concat(".addresses.", ADAPTER_DEPLOYMENT_KEY))) {
            require(deployments.readAddress(string.concat(".addresses.", ADAPTER_DEPLOYMENT_KEY)) == bridgeAdapter, "recorded adapter != predicted CREATE3 address");
        }
    }

    // ── Preconditions ─────────────────────────────────────────────────────────────

    function _checkPreconditions() internal view {
        _assertGovernance();
        _assertUnwrapper();
        _assertTopupRail();
    }

    /// @dev The whole one-bundle-no-timelock premise, plus both idempotence gates.
    function _assertGovernance() internal view {
        // Both calls are owner-gated and the Safe signs them directly. The factory reads the SAME
        // registry, so one owner check covers both — asserted rather than assumed.
        require(roleRegistry.owner() == SAFE, "Ethereum RoleRegistry owner is not the Safe - both calls would revert; use the owner's governance path");
        require(address(factory.roleRegistry()) == address(roleRegistry), "TopUpFactory reads a different RoleRegistry than the one being granted on");

        require(!roleRegistry.hasRole(adminRole, SAFE), "Safe already holds STOCK_UNWRAPPER_ADMIN_ROLE - grant already done?");

        // Emergency stop on both contracts, which is why call 1 is not launch-blocking.
        require(roleRegistry.hasRole(roleRegistry.PAUSER(), SAFE), "Safe lacks PAUSER on the Ethereum registry");
        require(roleRegistry.hasRole(roleRegistry.UNPAUSER(), SAFE), "Safe lacks UNPAUSER on the Ethereum registry");
    }

    /// @dev Handing admin to the Safe is only meaningful if the contract it administers is the one
    ///      this repo deployed and it is already fully configured. deployments.json is
    ///      hand-maintained, so the CREATE3 salt and the proxy's own storage establish that.
    function _assertUnwrapper() internal view {
        _assertProdAddresses();
        require(address(unwrapper).code.length > 0, "StockUnwrapper has no code at the recorded address");
        require(address(unwrapper) == _predictAddress(_unwrapperProxySalt()), "recorded unwrapper != Prod.StockWithdraw.StockUnwrapperProxy.V2 CREATE3 address");
        require(adminRole == keccak256("STOCK_UNWRAPPER_ADMIN_ROLE"), "unwrapper reports an unexpected admin role - wrong address?");

        address storedRegistry = address(uint160(uint256(vm.load(address(unwrapper), UPGRADEABLE_PROXY_STORAGE_SLOT))));
        require(storedRegistry == address(roleRegistry), "unwrapper roleRegistry mismatch - possible hijack");

        require(unwrapper.getLzEndpoint() == LZ_ENDPOINT_ETHEREUM, "unwrapper points at a different LZ endpoint");
        require(unwrapper.getSrcEid() == OP_EID, "unwrapper srcEid is not OP");
        require(unwrapper.getSrcModule() == bytes32(uint256(uint160(_predictAddress(_moduleProxySalt())))), "unwrapper trusts a different OP module");

        // The adapter allowlist is what AUTHENTICATES a compose, so it must already be complete.
        _assertAssetRails(false);
        (address[] memory adapters,) = _adapters();
        for (uint256 i = 0; i < adapters.length; i++) {
            require(unwrapper.isRegisteredAdapter(adapters[i]), "unwrapper does not register a configured adapter");
        }
        require(unwrapper.getRegisteredAdapters().length == adapters.length, "unwrapper registers a different NUMBER of adapters than configured");
    }

    /// @dev Everything the token configs assert about themselves, off-line, before signing.
    function _assertTopupRail() internal view {
        _assertAssetWiring();

        require(bridgeAdapter.code.length > 0, "StockOFTBridgeAdapter not deployed - deploy it before signing this bundle");
        require(address(factory).code.length > 0, "TopUpFactory has no code");
        require(recipient != address(0), "OP TopUpDest missing from deployments/mainnet/10");

        // The factory's own validation, re-checked here so a bad constant fails before signing
        // rather than reverting the Safe transaction.
        require(MAX_SLIPPAGE_BPS > 0, "maxSlippageInBps must be nonzero or the route cannot be quoted");
        require(MAX_SLIPPAGE_BPS <= factory.MAX_ALLOWED_SLIPPAGE(), "maxSlippageInBps exceeds TopUpFactory.MAX_ALLOWED_SLIPPAGE");
        require(LZ_RECEIVE_GAS > 0, "lzReceiveGas must be nonzero: Backed OFTs have no enforced SEND options");

        StockTopupAsset[] memory assets = _assets();
        for (uint256 i = 0; i < assets.length; i++) {
            TopUpFactory.TokenConfig memory existing = factory.getTokenConfig(assets[i].stock, OP_CHAIN_ID);
            require(existing.bridgeAdapter == address(0), string.concat(assets[i].symbol, ": already configured for chain 10 - this bundle would overwrite a live route"));
            require(IERC4626(assets[i].wrapper).previewDeposit(1e18) > 0, string.concat(assets[i].symbol, ": wrapper previews a zero-share deposit"));
        }
    }

    // ── Bundle construction ───────────────────────────────────────────────────────

    function _grantRoleData() internal view returns (bytes memory) {
        return abi.encodeWithSignature("grantRole(bytes32,address)", adminRole, SAFE);
    }

    function _setTokenConfigData() internal view returns (bytes memory) {
        StockTopupAsset[] memory assets = _assets();
        uint256 len = assets.length;

        address[] memory tokens = new address[](len);
        uint256[] memory chainIds = new uint256[](len);
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](len);

        for (uint256 i = 0; i < len; i++) {
            tokens[i] = assets[i].stock;
            chainIds[i] = OP_CHAIN_ID;
            configs[i] = _tokenConfig(bridgeAdapter, recipient, assets[i].oftAdapter);
        }

        return abi.encodeWithSelector(TopUpFactory.setTokenConfig.selector, tokens, chainIds, configs);
    }

    function _writeBundle() internal returns (string memory path) {
        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(SAFE));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(roleRegistry)), iToHex(_grantRoleData()), "0", false));
        txs = string.concat(txs, _getGnosisTransaction(addressToHex(address(factory)), iToHex(_setTokenConfigData()), "0", true));

        vm.createDir("./output", true);
        path = string.concat("./output/3CP-647-ConfigureStockRail-eth-", vm.toString(block.chainid), ".json");
        vm.writeFile(path, txs);
        console.log("Wrote", path);
    }

    // ── Fork simulation ───────────────────────────────────────────────────────────

    function _simulateAndVerify(string memory path) internal {
        console.log("");
        console.log("=== Simulating the Ethereum bundle ===");
        console.log("  unwrapper:     ", address(unwrapper));
        console.log("  bridge adapter:", bridgeAdapter);
        console.log("  recipient (OP TopUpDest):", recipient);

        address ownerBefore = roleRegistry.owner();
        uint256 adaptersBefore = unwrapper.getRegisteredAdapters().length;

        executeGnosisTransactionBundle(path);

        _assertGrantLeg(adaptersBefore);
        _assertTopupLeg();

        // Collateral damage: neither call may move ownership or the pause state.
        require(roleRegistry.owner() == ownerBefore, "SIM FAILED: RoleRegistry owner changed");
        require(!unwrapper.paused(), "SIM FAILED: unwrapper ended up paused");
        require(!factory.paused(), "SIM FAILED: TopUpFactory ended up paused");

        console.log("");
        console.log("3CP-647 simulation passed.");
    }

    /// @dev Leg 1. A matching role hash is not proof the role WORKS, so drive a real admin setter
    ///      as the Safe — re-registering the already-registered adapters, so config cannot change.
    function _assertGrantLeg(uint256 adaptersBefore) internal {
        require(roleRegistry.hasRole(adminRole, SAFE), "SIM FAILED: Safe did not receive STOCK_UNWRAPPER_ADMIN_ROLE");

        (address[] memory adapters, bool[] memory registered) = _adapters();
        vm.prank(SAFE);
        unwrapper.configureAdapters(adapters, registered);
        require(unwrapper.getRegisteredAdapters().length == adaptersBefore, "SIM FAILED: the no-op admin call changed the adapter set");

        console.log("");
        console.log("  [OK] STOCK_UNWRAPPER_ADMIN_ROLE held by the Safe, setters callable");
    }

    /// @dev Leg 2. Storage equality per field, then the thing that actually matters: the route has
    ///      to be QUOTABLE at the live executor config.
    function _assertTopupLeg() internal {
        StockTopupAsset[] memory assets = _assets();

        for (uint256 i = 0; i < assets.length; i++) {
            StockTopupAsset memory a = assets[i];

            TopUpFactory.TokenConfig memory stored = factory.getTokenConfig(a.stock, OP_CHAIN_ID);
            require(stored.bridgeAdapter == bridgeAdapter, string.concat("SIM FAILED: ", a.symbol, " bridgeAdapter"));
            require(stored.recipientOnDestChain == recipient, string.concat("SIM FAILED: ", a.symbol, " recipient"));
            require(stored.maxSlippageInBps == MAX_SLIPPAGE_BPS, string.concat("SIM FAILED: ", a.symbol, " slippage"));
            require(keccak256(stored.additionalData) == keccak256(_additionalData(a.oftAdapter)), string.concat("SIM FAILED: ", a.symbol, " additionalData"));
            require(factory.isTokenSupported(a.stock), string.concat("SIM FAILED: ", a.symbol, " not in the factory's supported set"));

            (, uint256 fee) = factory.getBridgeFee(a.stock, 1e18, OP_CHAIN_ID);
            require(fee > 0, string.concat("SIM FAILED: ", a.symbol, " quoted a zero bridge fee - route not quotable"));
            console.log(string.concat("  [OK] ", a.symbol, " route quotable. Fee for 1e18 (wei):"), fee);

            if (vm.envOr("SIMULATE_BRIDGE", false)) _simulateBridge(a);
        }
    }

    /// @dev Opt-in end-to-end leg (`SIMULATE_BRIDGE=true`): funds the factory on the fork and
    ///      performs a real wrap + OFT send, so the wrapper deposit and the LayerZero send are
    ///      exercised rather than just quoted. Off by default because it depends on cheatcode
    ///      balance-slot discovery for third-party rebasing tokens, and a harness failure there
    ///      must not block bundle generation.
    function _simulateBridge(StockTopupAsset memory a) internal {
        uint256 amount = 1e18;
        deal(a.stock, address(factory), amount);
        vm.deal(address(factory), 1 ether);

        uint256 lockedBefore = IERC20(a.wrapper).balanceOf(a.oftAdapter);

        vm.prank(SAFE);
        roleRegistry.grantRole(factory.TOPUP_FACTORY_BRIDGER_ROLE(), SAFE);
        vm.prank(SAFE);
        factory.bridge(a.stock, amount, OP_CHAIN_ID);

        uint256 locked = IERC20(a.wrapper).balanceOf(a.oftAdapter);
        require(IERC20(a.stock).balanceOf(address(factory)) == 0, string.concat("SIM FAILED: ", a.symbol, " raw stock left in the factory"));
        require(locked > lockedBefore, string.concat("SIM FAILED: ", a.symbol, " adapter locked no wrapper shares"));
        require(IERC20(a.wrapper).balanceOf(address(factory)) == 0, string.concat("SIM FAILED: ", a.symbol, " wrapper shares left in the factory"));

        console.log(string.concat("       end-to-end wrap + OFT send OK. Shares locked:"), locked - lockedBefore);
    }
}
