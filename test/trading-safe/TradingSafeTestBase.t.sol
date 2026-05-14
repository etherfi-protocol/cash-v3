// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";

/**
 * @dev Shared scaffolding for trading-safe tests.
 *
 *      Wires up a real `EtherFiDataProvider` + `RoleRegistry`. The data provider's
 *      `_etherFiSafeFactory` slot is the TradingSafeFactory itself — on mainnet, the only
 *      EtherFiSafes ARE TradingSafes, so the factory is the source of truth for
 *      `isEtherFiSafe(address)`.
 *
 *      Deploy ordering breaks an init cycle:
 *        1. dataProvider proxy — uninitialised (we need its address to construct the role
 *           registry, which binds the data-provider address as immutable);
 *        2. role registry — proxy + initialise;
 *        3. TradingSafe impl (takes data-provider + bridge receiver);
 *        4. TradingSafeFactory — proxy + initialise (takes role registry + TradingSafe impl);
 *        5. dataProvider.initialize — now we have the safe-factory address.
 *
 *      Concrete tests bring their own `bridgeReceiver` address (a placeholder for the
 *      TradingSafe unit tests; the real OwnershipBridgeReceiver address for the receiver
 *      end-to-end tests, computed via `vm.computeCreateAddress`).
 */
abstract contract TradingSafeTestBase is Test {
    EtherFiDataProvider public dataProvider;
    RoleRegistry public roleRegistry;
    address public owner = makeAddr("owner");

    function _setupCore() internal {
        // 1. dataProvider proxy, uninitialised — its address is captured by the role
        //    registry's immutable below.
        address dataProviderImpl = address(new EtherFiDataProvider());
        dataProvider = EtherFiDataProvider(address(new UUPSProxy(dataProviderImpl, "")));

        // 2. role registry proxy + initialise.
        address roleRegistryImpl = address(new RoleRegistry(address(dataProvider)));
        roleRegistry = RoleRegistry(address(new UUPSProxy(
            roleRegistryImpl,
            abi.encodeWithSelector(RoleRegistry.initialize.selector, owner)
        )));
    }

    /// @dev Finalises data-provider setup with the deployed `safeFactory`. Required before
    ///      any TradingSafe can initialise — `_configureAdmin` calls
    ///      `dataProvider.isEtherFiSafe(self)`, which the data provider delegates to
    ///      `safeFactory.isEtherFiSafe(self)`.
    function _initDataProvider(address safeFactory) internal {
        address[] memory mods = new address[](1);
        mods[0] = makeAddr("dummyModule");
        address[] memory defaultMods = new address[](1);
        defaultMods[0] = makeAddr("dummyDefaultModule");

        EtherFiDataProvider.InitParams memory params = EtherFiDataProvider.InitParams({
            _roleRegistry: address(roleRegistry),
            _cashModule: address(0),
            _cashLens: address(0),
            _modules: mods,
            _defaultModules: defaultMods,
            _hook: address(0),
            _etherFiSafeFactory: safeFactory,
            _priceProvider: makeAddr("priceProvider"),
            _etherFiRecoverySigner: makeAddr("etherFiRecoverySigner"),
            _thirdPartyRecoverySigner: makeAddr("thirdPartyRecoverySigner"),
            _refundWallet: makeAddr("refundWallet")
        });
        dataProvider.initialize(params);
    }

    /// @dev Deploys a TradingSafe impl with the given `bridgeReceiver` and a factory proxy
    ///      pointing at it. Does NOT initialise the data provider — caller must do so via
    ///      `_initDataProvider(address(factory))` before deploying any TradingSafe.
    function _deployFactory(address bridgeReceiver) internal returns (TradingSafeFactory factory) {
        address tradingSafeImpl = address(new TradingSafe(address(dataProvider), bridgeReceiver));
        address factoryImpl = address(new TradingSafeFactory());
        factory = TradingSafeFactory(address(new UUPSProxy(
            factoryImpl,
            abi.encodeWithSelector(TradingSafeFactory.initialize.selector, address(roleRegistry), tradingSafeImpl)
        )));
    }

    /// @dev Deploys a TradingSafe via `factory`. Caller must hold
    ///      `TRADING_SAFE_FACTORY_ADMIN_ROLE` and be active via `vm.startPrank`. The factory
    ///      pre-registers the deterministic address in its set before the proxy initialises,
    ///      so the data-provider lookup succeeds during `_configureAdmin`.
    function _deployTradingSafe(
        TradingSafeFactory factory,
        address sourceSafe,
        address[] memory tsOwners,
        uint8 threshold
    ) internal returns (TradingSafe) {
        address predicted = factory.getDeterministicAddress(sourceSafe);
        address[] memory mods = new address[](0);
        bytes[] memory setupData = new bytes[](0);
        factory.deployTradingSafe(sourceSafe, tsOwners, mods, setupData, threshold);
        return TradingSafe(payable(predicted));
    }
}
