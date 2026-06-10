// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Test } from "forge-std/Test.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IConfigurableOFT } from "../../src/interfaces/IConfigurableOFT.sol";
import { IOFTConfigRegistry } from "../../src/interfaces/IOFTConfigRegistry.sol";
import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../../src/oft/EtherFiShadowOFT.sol";
import { OFTAdapterFactory } from "../../src/oft/OFTAdapterFactory.sol";
import { OFTConfigRegistry } from "../../src/oft/OFTConfigRegistry.sol";
import { ShadowOFTFactory } from "../../src/oft/ShadowOFTFactory.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

// --------------------------------------------------------------------------
// Mocks
// --------------------------------------------------------------------------

/**
 *   Minimal LayerZero endpoint stand-in. Our contracts only call `setDelegate` (during initialize)
 *    and `setConfig` (during syncConfig); this records those so tests can assert the bridge
 *    configured itself. It does NOT route messages, so it can't drive a full cross-chain round-trip.
 */
contract MockLZEndpoint {
    struct ConfigCall {
        address oapp;
        address lib;
        uint32 eid;
        bytes config;
    }

    mapping(address oapp => address) public delegates;
    ConfigCall[] public configCalls;

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }

    function setConfig(address _oapp, address _lib, SetConfigParam[] calldata _params) external {
        for (uint256 i; i < _params.length; ++i) {
            configCalls.push(ConfigCall(_oapp, _lib, _params[i].eid, _params[i].config));
        }
    }

    function configCallCount() external view returns (uint256) {
        return configCalls.length;
    }
}

/**
 *   ERC-20 with configurable decimals, so one mock stands in for USDC(6) / WBTC(8) / PAXG(18).
 */
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 *   Fee-on-transfer token: skims `feeBps` on every transfer so a lock receives less than was sent
 *    — exercises the adapter's lossless guard. Mint/burn are NOT taxed so funding stays clean.
 */
contract MockFeeOnTransferERC20 is ERC20 {
    uint8 private immutable _decimals;
    uint256 public feeBps; // e.g. 10 = 0.10%

    constructor(uint8 decimals_, uint256 feeBps_) ERC20("Fee Token", "FEE") {
        _decimals = decimals_;
        feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     *   OpenZeppelin's ERC-20 funnels EVERY balance change — mint, burn, and transfer — through this
     *   single `_update` hook (it's the one place balances actually move). Overriding it is the
     *   canonical way to build a fee-on-transfer token: on a real transfer we divert `feeBps` of the
     *   amount to a dead address, so the recipient (here, the adapter) ends up with LESS than was
     *   sent. Mint/burn (from/to == 0) are left untaxed so test funding stays exact.
     */
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value); // mint/burn untaxed
            return;
        }
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, address(0xdead), fee); // recipient gets less
        super._update(from, to, value - fee);
    }
}

/**
 *   Fake bridge that records syncConfig calls, so registry push/enumeration can be asserted
 *   without deploying a real OFT + endpoint.
 */
contract MockConfigurableOFT is IConfigurableOFT {
    address public immutable configRegistry;
    uint256 public syncCallCount;
    uint32[] public lastDstEids;

    constructor(address _registry) {
        configRegistry = _registry;
    }

    function syncConfig(uint32[] calldata dstEids) external override {
        syncCallCount += 1;
        delete lastDstEids;
        for (uint256 i; i < dstEids.length; ++i) {
            lastDstEids.push(dstEids[i]);
        }
    }

    function lastDstEidsLength() external view returns (uint256) {
        return lastDstEids.length;
    }
}

/**
 *   --------------------------------------------------------------------------
 *    Shared setup
 *   --------------------------------------------------------------------------
 */
contract OFTTestSetup is Test {
    RoleRegistry internal roleRegistry;
    OFTConfigRegistry internal configRegistry;
    OFTAdapterFactory internal adapterFactory;
    ShadowOFTFactory internal shadowFactory;
    MockLZEndpoint internal endpoint;

    address internal adapterImpl;
    address internal shadowImpl;

    // actors
    address internal owner = makeAddr("owner");
    address internal configAdmin = makeAddr("configAdmin");
    address internal factoryAdmin = makeAddr("factoryAdmin");
    address internal registrar = makeAddr("registrar");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal delegate = makeAddr("delegate");
    address internal alice = makeAddr("alice");

    // mock tokens
    MockERC20 internal token6;
    MockERC20 internal token8;
    MockERC20 internal token18;

    // LayerZero V2 endpoint IDs (NOT evm chainIds) for the two chains this primitive bridges:
    // Ethereum mainnet (30101) and Optimism (30111).
    uint32 internal constant DST_EID_OP = 30_111;
    uint32 internal constant DST_EID_ETH = 30_101;

    function setUp() public virtual {
        vm.startPrank(owner);

        // RoleRegistry (dataProvider dependency is unused on the paths we exercise)
        address dataProvider = makeAddr("dataProvider");
        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        endpoint = new MockLZEndpoint();

        // Config registry
        address configRegistryImpl = address(new OFTConfigRegistry());
        configRegistry = OFTConfigRegistry(address(new UUPSProxy(configRegistryImpl, abi.encodeWithSelector(OFTConfigRegistry.initialize.selector, address(roleRegistry)))));

        // Beacon impls (registry + endpoint fixed per chain)
        adapterImpl = address(new EtherFiOFTAdapter(address(endpoint), address(configRegistry)));
        shadowImpl = address(new EtherFiShadowOFT(address(endpoint), address(configRegistry)));

        // Factories
        address adapterFactoryImpl = address(new OFTAdapterFactory());
        adapterFactory = OFTAdapterFactory(address(new UUPSProxy(adapterFactoryImpl, abi.encodeWithSelector(OFTAdapterFactory.initialize.selector, address(roleRegistry), adapterImpl))));
        address shadowFactoryImpl = address(new ShadowOFTFactory());
        shadowFactory = ShadowOFTFactory(address(new UUPSProxy(shadowFactoryImpl, abi.encodeWithSelector(ShadowOFTFactory.initialize.selector, address(roleRegistry), shadowImpl))));

        // Roles
        roleRegistry.grantRole(configRegistry.CONFIG_ADMIN_ROLE(), configAdmin);
        roleRegistry.grantRole(configRegistry.CONFIG_REGISTRAR_ROLE(), registrar);
        // factories auto-register bridges at deploy -> need the registrar role
        roleRegistry.grantRole(configRegistry.CONFIG_REGISTRAR_ROLE(), address(adapterFactory));
        roleRegistry.grantRole(configRegistry.CONFIG_REGISTRAR_ROLE(), address(shadowFactory));
        roleRegistry.grantRole(adapterFactory.OFT_ADAPTER_FACTORY_ADMIN_ROLE(), factoryAdmin);
        roleRegistry.grantRole(shadowFactory.SHADOW_OFT_FACTORY_ADMIN_ROLE(), factoryAdmin);

        vm.stopPrank();

        token6 = new MockERC20("USD Coin", "USDC", 6);
        token8 = new MockERC20("Wrapped BTC", "WBTC", 8);
        token18 = new MockERC20("Pax Gold", "PAXG", 18);
    }

    // A valid 2-of-2 required-DVN pathway config (mirrors the weETH DVN stack shape).
    function _samplePathway(uint64 confirmations) internal returns (IOFTConfigRegistry.PathwayConfig memory cfg) {
        address[] memory required = new address[](2);
        required[0] = makeAddr("layerZeroDVN");
        required[1] = makeAddr("nethermindDVN");
        // requiredDVNs must be sorted ascending / unique per LZ; sort the two.
        if (required[0] > required[1]) (required[0], required[1]) = (required[1], required[0]);

        cfg = IOFTConfigRegistry.PathwayConfig({ sendLib: makeAddr("sendUln302"), receiveLib: makeAddr("receiveUln302"), confirmations: confirmations, optionalDVNThreshold: 0, requiredDVNs: required, optionalDVNs: new address[](0) });
    }
}
