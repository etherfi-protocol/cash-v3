// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, OFTReceipt, SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../../src/oft/EtherFiShadowOFT.sol";
import { PairwiseRateLimiter } from "../../src/oft/PairwiseRateLimiter.sol";
import { OFTAdapterFactory } from "../../src/oft/OFTAdapterFactory.sol";
import { OFTConfigRegistry } from "../../src/oft/OFTConfigRegistry.sol";
import { ShadowOFTFactory } from "../../src/oft/ShadowOFTFactory.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { MockERC20 } from "./OFTTestSetup.t.sol";

/**
 * @title OFTCrossChainSetup
 * @notice Real LayerZero round-trip harness. Unlike the recording `MockLZEndpoint` in
 *         {OFTTestSetup}, this wires two live `EndpointV2Mock`s in one EVM via LZ's
 *         {TestHelperOz5} and delivers packets in-process (`send()` -> `verifyPackets()`),
 *         so the full lock -> mint -> burn -> unlock path — message encode/decode, peer
 *         enforcement, SD<->LD truncation in transit — is exercised end to end.
 *
 *         Endpoint 1 stands in for mainnet (the lock adapter); endpoint 2 for Optimism
 *         (the mintable iTOKEN). Both factories/impls live in one EVM but are pinned to
 *         their respective endpoints via the impl constructor, exactly as on real chains.
 */
contract OFTCrossChainSetup is TestHelperOz5 {
    using OptionsBuilder for bytes;

    // TestHelperOz5 assigns eid = index + 1. Endpoint 1 = "mainnet", endpoint 2 = "OP".
    uint32 internal constant A_EID = 1; // mainnet (adapter / lock side)
    uint32 internal constant B_EID = 2; // OP (shadow iTOKEN / mint side)

    uint8 internal constant SHARED_DECIMALS = 6;

    RoleRegistry internal roleRegistry;
    OFTConfigRegistry internal configRegistry; // one EVM -> one shared registry is fine

    OFTAdapterFactory internal adapterFactory; // pinned to endpoint A
    ShadowOFTFactory internal shadowFactory; // pinned to endpoint B

    // The active pair under test, set by {_deployPair}.
    MockERC20 internal underlying;
    EtherFiOFTAdapter internal adapter;
    EtherFiShadowOFT internal shadow;

    // actors
    address internal owner = makeAddr("owner");
    address internal factoryAdmin = makeAddr("factoryAdmin");
    address internal delegate = makeAddr("delegate"); // OApp owner / LZ delegate on both ends
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual override {
        // Wire two live LZ endpoints + default DVN/executor/library config between them.
        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        vm.startPrank(owner);

        address dataProvider = makeAddr("dataProvider");
        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        address configRegistryImpl = address(new OFTConfigRegistry());
        configRegistry = OFTConfigRegistry(address(new UUPSProxy(configRegistryImpl, abi.encodeWithSelector(OFTConfigRegistry.initialize.selector, address(roleRegistry)))));

        // Adapter impl/factory pinned to mainnet endpoint; shadow impl/factory to OP endpoint.
        address adapterImpl = address(new EtherFiOFTAdapter(endpoints[A_EID], address(configRegistry)));
        address shadowImpl = address(new EtherFiShadowOFT(endpoints[B_EID], address(configRegistry)));

        address adapterFactoryImpl = address(new OFTAdapterFactory());
        adapterFactory = OFTAdapterFactory(address(new UUPSProxy(adapterFactoryImpl, abi.encodeWithSelector(OFTAdapterFactory.initialize.selector, address(roleRegistry), adapterImpl))));
        address shadowFactoryImpl = address(new ShadowOFTFactory());
        shadowFactory = ShadowOFTFactory(address(new UUPSProxy(shadowFactoryImpl, abi.encodeWithSelector(ShadowOFTFactory.initialize.selector, address(roleRegistry), shadowImpl))));

        // Roles: factories auto-register their bridges at deploy, so they need the registrar role.
        roleRegistry.grantRole(configRegistry.CONFIG_REGISTRAR_ROLE(), address(adapterFactory));
        roleRegistry.grantRole(configRegistry.CONFIG_REGISTRAR_ROLE(), address(shadowFactory));
        roleRegistry.grantRole(adapterFactory.OFT_ADAPTER_FACTORY_ADMIN_ROLE(), factoryAdmin);
        roleRegistry.grantRole(shadowFactory.SHADOW_OFT_FACTORY_ADMIN_ROLE(), factoryAdmin);

        vm.stopPrank();

        // Native gas for paying LZ messaging fees on send().
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /**
     * @notice Deploy a fresh adapter+shadow pair for an underlying of `decimals` precision and
     *         wire them as peers. The registry has no active pathway, so the factory auto-sync
     *         is a no-op and message routing falls back to TestHelperOz5's default DVN config.
     */
    function _deployPair(uint8 decimals) internal {
        underlying = new MockERC20("Underlying", "UND", decimals);

        vm.startPrank(factoryAdmin);
        adapter = EtherFiOFTAdapter(adapterFactory.deployAdapter(keccak256(abi.encode("adapter", address(underlying))), address(underlying), delegate));
        shadow = EtherFiShadowOFT(shadowFactory.deployShadowOFT(keccak256(abi.encode("shadow", address(underlying))), "EtherFi UND", "iUND", decimals, delegate));
        vm.stopPrank();

        // Peer wiring is owner-gated (delegate is the OApp owner on both ends).
        vm.startPrank(delegate);
        adapter.setPeer(B_EID, _b32(address(shadow)));
        shadow.setPeer(A_EID, _b32(address(adapter)));
        vm.stopPrank();

        // The limiter is fail-closed; lift it to effectively-unlimited so the round-trip / conservation
        // tests exercise the full bridge path. Dedicated rate-limit tests set precise caps instead.
        _liftRateLimits(address(adapter), B_EID);
        _liftRateLimits(address(shadow), A_EID);
    }

    /// @dev Lift the fail-closed rate limit (both directions) for a peer eid on a bridge, as the delegate.
    function _liftRateLimits(address bridge, uint32 eid) internal {
        PairwiseRateLimiter.RateLimitConfig[] memory cfg = new PairwiseRateLimiter.RateLimitConfig[](1);
        cfg[0] = PairwiseRateLimiter.RateLimitConfig({ peerEid: eid, limit: type(uint256).max, window: 1 });
        vm.startPrank(delegate);
        PairwiseRateLimiter(bridge).setOutboundRateLimits(cfg);
        PairwiseRateLimiter(bridge).setInboundRateLimits(cfg);
        vm.stopPrank();
    }

    /**
     * @notice Lock `amountLD` of underlying in the mainnet adapter and deliver the resulting
     *         mint on OP. Returns the adapter's OFTReceipt (sent/received, post dust removal).
     */
    function _bridgeOut(address user, uint256 amountLD) internal returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory sp = SendParam(B_EID, _b32(user), amountLD, 0, options, "", "");
        MessagingFee memory fee = adapter.quoteSend(sp, false);

        vm.startPrank(user);
        underlying.approve(address(adapter), amountLD);
        (, OFTReceipt memory r) = adapter.send{ value: fee.nativeFee }(sp, fee, payable(user));
        vm.stopPrank();

        // Deliver the in-flight packet to the OP shadow (mints iTOKEN).
        verifyPackets(B_EID, _b32(address(shadow)));
        return (r.amountSentLD, r.amountReceivedLD);
    }

    /**
     * @notice Burn `amountLD` of iTOKEN on OP and deliver the unlock on mainnet to `user`.
     */
    function _bridgeBack(address user, uint256 amountLD) internal returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory sp = SendParam(A_EID, _b32(user), amountLD, 0, options, "", "");
        MessagingFee memory fee = shadow.quoteSend(sp, false);

        vm.startPrank(user);
        (, OFTReceipt memory r) = shadow.send{ value: fee.nativeFee }(sp, fee, payable(user));
        vm.stopPrank();

        verifyPackets(A_EID, _b32(address(adapter)));
        return (r.amountSentLD, r.amountReceivedLD);
    }

    /// @dev adapter underlying balance == tokens locked == should equal shadow.totalSupply (decimals match).
    function _locked() internal view returns (uint256) {
        return underlying.balanceOf(address(adapter));
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
