// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { Utils } from "../utils/Utils.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { AcrossSwapModule } from "../../src/across/AcrossSwapModule.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { OwnershipBridgeReceiver } from "../../src/ownership-bridge/OwnershipBridgeReceiver.sol";
import { PriceProviderV2 } from "../../src/oracle/PriceProviderV2.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";

/**
 * @title DeployTradingAccountMainnet
 * @notice Dev/testnet deploy of the destination-chain (Ethereum) trading-account stack,
 *         routed entirely through our cross-chain `EtherFiDeployer` (CREATE3). Same salt
 *         on any chain ⇒ same address, since the deployer itself lives at the same
 *         address everywhere.
 *
 *         EVERY proxy is deployed with its initialize calldata in the deployment tx —
 *         a deploy-then-initialize split is front-runnable (ownership takeover) between
 *         the two transactions. Circular references (receiver -> factory -> safe-impl,
 *         InitParams -> module/factory -> DataProvider) are broken with CREATE3 address
 *         prediction: constructors STORE predicted addresses before the code exists, and
 *         each deploy asserts it landed on its prediction. AcrossSwapModule deploys last
 *         because its constructor CALLS the DataProvider (needs it deployed+initialised).
 *
 * Run:
 *   
 *   source .env && ENV=DEV forge script scripts/trading-account/DeployTradingAccountMainnet.s.sol --rpc-url mainnet --broadcast -vvv --verify
 */
contract DeployTradingAccountMainnet is Utils {
    // Our cross-chain CREATE3 deployer — same address on every chain.
    EtherFiDeployer constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);

    // LayerZero v2 endpoint — same address on Ethereum and Optimism.
    address constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    // LZ EID of the source chain (Optimism) the receiver trusts.
    uint32 constant OP_EID = 30111;

    // Across V3 on Ethereum mainnet.
    address constant SPOKE_POOL = 0x5c7BCd6E7De5423a257D81B442095A1a6ced35C5;
    address constant MULTICALL_HANDLER = 0x924a9f036260DdD5808007E1AA95f08eD08aA569;

    address constant RECOVERY_SIGNER_1 = 0xbfCe61CE31359267605F18dcE65Cb6c3cc9694A7;
    address constant RECOVERY_SIGNER_2 = 0xa265C271adbb0984EFd67310cfe85A77f449e291;

    // Deployed addresses live in script state (not locals) to stay under the legacy
    // codegen's per-frame stack budget.
    address internal deployer;
    address internal keeper;
    address internal predictedDataProvider;
    address internal predictedFactory;
    address internal predictedAcrossModule;
    RoleRegistry internal roleRegistry;
    PriceProviderV2 internal priceProvider;
    OwnershipBridgeReceiver internal receiver;
    address internal tradingSafeImpl;
    TradingSafeFactory internal factory;
    TradingLens internal lens;
    EtherFiDataProvider internal dataProvider;
    AcrossSwapModule internal acrossModule;
    // Existing TopUp source factory (not deployed here) — the `isTokenSupported` oracle the
    // factory's `redirectToTopUp` consults. Read from this chain's deployments.json.
    address internal topUpFactory;

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);
        keeper = deployer;

        require(DEPLOYER.isDeployer(deployer), "broadcaster not registered on EtherFiDeployer");

        vm.startBroadcast(pk);

        // 1. Predict every address that must be referenced before it exists. All three
        //    are only STORED by the constructors/InitParams that consume them — nothing
        //    calls into them before they're deployed.
        predictedDataProvider = DEPLOYER.getDeterministicAddress(getSalt("TradingDataProviderProxyDev"));
        predictedFactory = DEPLOYER.getDeterministicAddress(getSalt("TradingSafeFactoryProxyDev"));
        predictedAcrossModule = DEPLOYER.getDeterministicAddress(getSalt("AcrossSwapModuleDev"));

        _deployCore();
        _deployBridgeAndFactory();
        _deployDataProviderAndModule();
        _configureRolesAndAcross();

        vm.stopBroadcast();

        _persistAndLog();
    }

    /// @dev RoleRegistry (pins the predicted DataProvider as immutable; deployer is dev
    ///      owner) + PriceProviderV2 with no token configs — trading tokens (SPYon etc.)
    ///      get their oracle config via setTokenConfig once the asset list is locked.
    ///      Both proxies initialise atomically in their deployment txs.
    function _deployCore() internal {
        address roleRegistryImpl = _deploy(
            "TradingRoleRegistryImplDev", type(RoleRegistry).creationCode, abi.encode(predictedDataProvider)
        );
        roleRegistry = RoleRegistry(_deployProxy(
            "TradingRoleRegistryProxyDev",
            roleRegistryImpl,
            abi.encodeWithSelector(RoleRegistry.initialize.selector, deployer)
        ));

        address priceProviderImpl = _deploy("TradingPriceProviderImplDev", type(PriceProviderV2).creationCode, "");
        address[] memory noTokens = new address[](0);
        PriceProviderV2.Config[] memory noConfigs = new PriceProviderV2.Config[](0);
        priceProvider = PriceProviderV2(_deployProxy(
            "TradingPriceProviderProxyDev",
            priceProviderImpl,
            abi.encodeWithSelector(PriceProviderV2.initialize.selector, address(roleRegistry), noTokens, noConfigs)
        ));
    }

    /// @dev OwnershipBridgeReceiver pins the PREDICTED factory (peer to the OP sender is
    ///      set by the wire script); TradingSafe impl stores the predicted DataProvider;
    ///      the factory proxy then initialises atomically at exactly the predicted address.
    function _deployBridgeAndFactory() internal {
        address receiverImpl = _deploy(
            "OwnershipBridgeReceiverImplDev",
            type(OwnershipBridgeReceiver).creationCode,
            abi.encode(LZ_ENDPOINT, OP_EID, predictedFactory)
        );
        receiver = OwnershipBridgeReceiver(_deployProxy(
            "OwnershipBridgeReceiverProxyDev",
            receiverImpl,
            abi.encodeWithSelector(OwnershipBridgeReceiver.initialize.selector, deployer, address(roleRegistry))
        ));

        tradingSafeImpl = _deploy(
            "TradingSafeImplDev", type(TradingSafe).creationCode, abi.encode(predictedDataProvider, address(receiver))
        );
        address factoryImpl = _deploy("TradingSafeFactoryImplDev", type(TradingSafeFactory).creationCode, "");
        factory = TradingSafeFactory(_deployProxy(
            "TradingSafeFactoryProxyDev",
            factoryImpl,
            abi.encodeWithSelector(TradingSafeFactory.initialize.selector, address(roleRegistry), tradingSafeImpl)
        ));
        require(address(factory) == predictedFactory, "factory landed off-prediction");

        address lensImpl = _deploy(
            "TradingLensImplDev", type(TradingLens).creationCode, abi.encode(address(priceProvider))
        );
        lens = TradingLens(_deployProxy(
            "TradingLensProxyDev",
            lensImpl,
            abi.encodeWithSelector(TradingLens.initialize.selector, address(roleRegistry))
        ));
    }

    /// @dev DataProvider initialises atomically with full InitParams; the across module is
    ///      referenced by prediction (stored only) and whitelisted + default so every
    ///      TradingSafe deploys with it installed. AcrossSwapModule deploys LAST because
    ///      its constructor CALLS dataProvider.getCashModule() (needs code there; returns 0
    ///      since InitParams set no cash module, permanently disabling the hold path —
    ///      correct for the mainnet TradingSafe: no card rail, no hold).
    function _deployDataProviderAndModule() internal {
        address[] memory modules = new address[](1);
        modules[0] = predictedAcrossModule;
        address dataProviderImpl = _deploy("TradingDataProviderImplDev", type(EtherFiDataProvider).creationCode, "");
        dataProvider = EtherFiDataProvider(_deployProxy(
            "TradingDataProviderProxyDev",
            dataProviderImpl,
            abi.encodeWithSelector(EtherFiDataProvider.initialize.selector, EtherFiDataProvider.InitParams({
                _roleRegistry: address(roleRegistry),
                _cashModule: address(0),
                _cashLens: address(0),
                _modules: modules,
                _defaultModules: modules,
                _hook: address(0),
                _etherFiSafeFactory: address(factory),
                _priceProvider: address(priceProvider),
                _etherFiRecoverySigner: RECOVERY_SIGNER_1,
                _thirdPartyRecoverySigner: RECOVERY_SIGNER_2,
                _refundWallet: deployer
            }))
        ));
        require(address(dataProvider) == predictedDataProvider, "dataProvider landed off-prediction");

        // Full Across config rides in the initialize calldata — atomic with the proxy
        // deploy. The module is Buy-only; there is no sell settlement on-chain anymore.
        address acrossImpl = _deploy(
            "AcrossSwapModuleImplDev", type(AcrossSwapModule).creationCode, abi.encode(address(dataProvider))
        );
        acrossModule = AcrossSwapModule(_deployProxy(
            "AcrossSwapModuleDev",
            acrossImpl,
            abi.encodeWithSelector(
                AcrossSwapModule.initialize.selector,
                address(roleRegistry),
                SPOKE_POOL,
                MULTICALL_HANDLER
            )
        ));
        require(address(acrossModule) == predictedAcrossModule, "across module landed off-prediction");
    }

    /// @dev Wires roles + both redirect directions. Safe → TopUp: `setTopUpFactory` (the
    ///      topup-supported-asset oracle), `setTradingLens`, and `TRADING_SAFE_REDIRECT_ROLE`.
    ///      TopUp → Safe (mainnet-only): point the TopUp source factory back at this
    ///      TradingSafeFactory and grant `TOPUP_FACTORY_REDIRECT_ROLE`. All owner-gated — on
    ///      dev the deployer owns both the trading and topup stacks.
    function _configureRolesAndAcross() internal {
        roleRegistry.grantRole(acrossModule.ACROSS_SWAP_MODULE_ADMIN_ROLE(), deployer);
        roleRegistry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), keeper);
        roleRegistry.grantRole(lens.TRADING_LENS_ADMIN_ROLE(), deployer);

        // Safe → TopUp redirect wiring. The TopUp source factory is deployed separately and
        // recorded in this chain's deployments.json.
        string memory topUpDeployments = readTopUpSourceDeployment();
        topUpFactory = stdJson.readAddress(topUpDeployments, ".addresses.TopUpSourceFactory");
        factory.setTopUpFactory(topUpFactory);
        roleRegistry.grantRole(factory.TRADING_SAFE_REDIRECT_ROLE(), keeper);

        // TopUp → Safe redirect now gates on trading-supported tokens; the factory reads that
        // from the TradingLens registry.
        factory.setTradingLens(address(lens));

        // TopUp → Safe redirect direction (mainnet-only — it makes synchronous calls into the
        // co-located TradingSafeFactory). Point the TopUp source factory at THIS chain's
        // TradingSafeFactory so destinations resolve, and grant the keeper the redirect role.
        // Both touch the TopUp stack's own RoleRegistry/owner — on dev the same deployer key.
        RoleRegistry topUpRoleRegistry = RoleRegistry(stdJson.readAddress(topUpDeployments, ".addresses.RoleRegistry"));
        TopUpFactory(payable(topUpFactory)).setTradingSafeFactory(address(factory));
        topUpRoleRegistry.grantRole(TopUpFactory(payable(topUpFactory)).TOPUP_FACTORY_REDIRECT_ROLE(), keeper);
    }

    /// @dev Persist for BE/FE integration + the wire script.
    function _persistAndLog() internal {
        string memory out = "trading-account-mainnet";
        vm.serializeAddress(out, "EtherFiDataProvider", address(dataProvider));
        vm.serializeAddress(out, "RoleRegistry", address(roleRegistry));
        vm.serializeAddress(out, "PriceProvider", address(priceProvider));
        vm.serializeAddress(out, "TradingSafeFactory", address(factory));
        vm.serializeAddress(out, "TradingSafeImpl", tradingSafeImpl);
        vm.serializeAddress(out, "OwnershipBridgeReceiver", address(receiver));
        vm.serializeAddress(out, "AcrossSwapModule", address(acrossModule));
        vm.serializeAddress(out, "TopUpFactory", topUpFactory);
        string memory json = vm.serializeAddress(out, "TradingLens", address(lens));
        vm.writeJson(json, string.concat(
            vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/trading-account.json"
        ));

        console.log("EtherFiDataProvider:    ", address(dataProvider));
        console.log("RoleRegistry:           ", address(roleRegistry));
        console.log("PriceProvider:          ", address(priceProvider));
        console.log("TradingSafeFactory:     ", address(factory));
        console.log("TradingSafeImpl:        ", tradingSafeImpl);
        console.log("OwnershipBridgeReceiver:", address(receiver));
        console.log("AcrossSwapModule:       ", address(acrossModule));
        console.log("TradingLens:            ", address(lens));
        console.log("TopUpFactory (wired):   ", topUpFactory);
    }

    /// @dev CREATE3-deploys `creationCode ++ constructorArgs` under a string salt.
    function _deploy(string memory saltName, bytes memory creationCode, bytes memory constructorArgs)
        internal
        returns (address)
    {
        return DEPLOYER.deploy(getSalt(saltName), abi.encodePacked(creationCode, constructorArgs));
    }

    /// @dev CREATE3-deploys a UUPSProxy pointing at `impl` with `initData`.
    function _deployProxy(string memory saltName, address impl, bytes memory initData) internal returns (address) {
        return _deploy(saltName, type(UUPSProxy).creationCode, abi.encode(impl, initData));
    }
}
