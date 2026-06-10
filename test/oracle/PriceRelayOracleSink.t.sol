// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {
    MessagingParams,
    MessagingReceipt,
    MessagingFee,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import { PriceRelay } from "../../src/oracle/PriceRelay.sol";
import { OracleSink } from "../../src/oracle/OracleSink.sol";
import { PriceProvider } from "../../src/oracle/PriceProvider.sol";
import { IPriceRelay } from "../../src/interfaces/IPriceRelay.sol";
import { IOracleSink } from "../../src/interfaces/IOracleSink.sol";
import { MockPriceProvider } from "../../src/mocks/MockPriceProvider.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";

/// @notice Minimal in-memory LayerZero EndpointV2 stand-in.
/// @dev Implements only the surface the OApp sender/receiver stack touches:
///      `setDelegate`, `quote`, `send`. Both the relay and the sink share one
///      instance (single local EVM), and `deliver` replays the captured packet
///      into the receiver's `lzReceive` with `msg.sender == endpoint` so the
///      OApp peer/origin checks run exactly as in production.
contract MockLZEndpoint {
    struct Sent {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        address sender;
        bytes32 guid;
    }

    uint256 public fee = 0.001 ether;
    Sent public last;
    bool public hasPending;

    function setFee(uint256 _fee) external {
        fee = _fee;
    }

    function setDelegate(address) external {}

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee({ nativeFee: fee, lzTokenFee: 0 });
    }

    function send(MessagingParams calldata _params, address) external payable returns (MessagingReceipt memory r) {
        bytes32 guid = keccak256(abi.encode(_params, msg.sender, block.timestamp));
        last = Sent({
            dstEid: _params.dstEid,
            receiver: _params.receiver,
            message: _params.message,
            options: _params.options,
            sender: msg.sender,
            guid: guid
        });
        hasPending = true;
        r.guid = guid;
        r.nonce = 1;
        r.fee = MessagingFee({ nativeFee: msg.value, lzTokenFee: 0 });
    }

    /// @notice Replays the last captured packet into `lzReceive` of the receiver.
    function deliver(uint32 srcEid) external {
        require(hasPending, "no pending packet");
        hasPending = false;
        ILzReceiver(address(uint160(uint256(last.receiver)))).lzReceive(
            Origin({ srcEid: srcEid, sender: bytes32(uint256(uint160(last.sender))), nonce: 1 }),
            last.guid,
            last.message,
            address(this),
            ""
        );
    }
}

interface ILzReceiver {
    function lzReceive(Origin calldata, bytes32, bytes calldata, address, bytes calldata) external payable;
}

/// @notice Thin per-token Chainlink-shaped adapter over the multi-token {OracleSink}.
/// @dev The OP {PriceProvider} Chainlink branch calls the no-arg `latestRoundData()`,
///      but the sink serves many tokens via `latestRoundData(token)`. This bakes in
///      the token so the sink can be consumed through `isChainlinkType = true` while
///      still exercising PriceProvider's staleness check. This is the recommended
///      production consumption pattern for a multi-token sink.
contract OracleSinkAggregatorAdapter {
    IOracleSink public immutable sink;
    address public immutable token;

    constructor(IOracleSink _sink, address _token) {
        sink = _sink;
        token = _token;
    }

    function decimals() external view returns (uint8) {
        return sink.decimals();
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return sink.latestRoundData(token);
    }
}

contract PriceRelayOracleSinkTest is Test {
    using OptionsBuilder for bytes;

    uint32 constant SRC_EID = 1; // "mainnet"
    uint32 constant DST_EID = 2; // "optimism"

    uint256 constant INITIAL_PRICE = 2000e6; // 6-decimal USD
    uint32 constant HEARTBEAT = 5 minutes;
    uint32 constant DEVIATION_BPS = 50; // 0.5%
    uint32 constant MAX_STALENESS = 2 days;

    MockLZEndpoint endpoint;
    RoleRegistry roleRegistry;
    MockPriceProvider mockPriceProvider;
    PriceRelay priceRelay;
    OracleSink oracleSink;

    address token = makeAddr("token");
    bytes lzOptions;

    function setUp() public {
        vm.warp(1_700_000_000);
        endpoint = new MockLZEndpoint();

        // Role registry (owner = this test contract).
        address roleRegistryImpl = address(new RoleRegistry(makeAddr("dataProvider")));
        roleRegistry = RoleRegistry(
            address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, address(this))))
        );

        // Mainnet source price provider.
        mockPriceProvider = new MockPriceProvider(INITIAL_PRICE, address(0));

        // PriceRelay (both OApps share the one local endpoint).
        address relayImpl = address(new PriceRelay(address(endpoint)));
        priceRelay = PriceRelay(
            payable(
                address(
                    new UUPSProxy(
                        relayImpl,
                        abi.encodeWithSelector(
                            PriceRelay.initialize.selector,
                            address(roleRegistry),
                            address(mockPriceProvider),
                            address(this),
                            DST_EID
                        )
                    )
                )
            )
        );

        // OracleSink.
        address sinkImpl = address(new OracleSink(address(endpoint)));
        oracleSink = OracleSink(
            address(
                new UUPSProxy(
                    sinkImpl, abi.encodeWithSelector(OracleSink.initialize.selector, address(roleRegistry), address(this))
                )
            )
        );

        // Peer wiring: enforces "only the mainnet relay can update the L2 sink".
        priceRelay.setPeer(DST_EID, _b32(address(oracleSink)));
        oracleSink.setPeer(SRC_EID, _b32(address(priceRelay)));

        // Admin config.
        roleRegistry.grantRole(priceRelay.PRICE_RELAY_ADMIN_ROLE(), address(this));
        lzOptions = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        priceRelay.setLzOptions(lzOptions);
        priceRelay.subscribe(
            token,
            IPriceRelay.TokenSubscription({ heartbeat: HEARTBEAT, deviationBps: DEVIATION_BPS, maxStaleness: MAX_STALENESS })
        );

        // Fund the relay so it can pay LZ fees itself.
        vm.deal(address(priceRelay), 100 ether);
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _single(address t) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = t;
    }

    function _singlePrice(uint256 p) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = p;
    }

    // --- Round trip --------------------------------------------------------

    function test_RoundTrip_relaysPriceToSink() public {
        priceRelay.poke(_single(token));
        endpoint.deliver(SRC_EID);

        (uint256 price, uint64 updatedAt) = oracleSink.getPrice(token);
        assertEq(price, INITIAL_PRICE);
        assertEq(updatedAt, uint64(block.timestamp));

        (uint256 lastPrice, uint64 lastTs) = priceRelay.lastRelayed(token);
        assertEq(lastPrice, INITIAL_PRICE);
        assertEq(lastTs, uint64(block.timestamp));
    }

    function test_RoundTrip_feePaidFromContractBalance() public {
        uint256 balanceBefore = address(priceRelay).balance;
        priceRelay.poke(_single(token));
        assertEq(address(priceRelay).balance, balanceBefore - endpoint.fee());
    }

    // --- Heartbeat gate ----------------------------------------------------

    function test_Heartbeat_triggersAfterInterval() public {
        priceRelay.poke(_single(token));
        endpoint.deliver(SRC_EID);

        // Within heartbeat, unchanged price -> nothing to relay.
        vm.warp(block.timestamp + 1);
        vm.expectRevert(IPriceRelay.NothingToRelay.selector);
        priceRelay.poke(_single(token));

        // After heartbeat -> relays again even with unchanged price.
        vm.warp(block.timestamp + HEARTBEAT);
        priceRelay.poke(_single(token));

        (, uint64 lastTs) = priceRelay.lastRelayed(token);
        assertEq(lastTs, uint64(block.timestamp));
    }

    // --- Deviation gate ----------------------------------------------------

    function test_Deviation_triggersOnPriceMove() public {
        priceRelay.poke(_single(token));
        endpoint.deliver(SRC_EID);

        // Move 1% (>= 0.5% threshold) within the heartbeat window.
        vm.warp(block.timestamp + 1);
        mockPriceProvider.setPrice((INITIAL_PRICE * 101) / 100);

        priceRelay.poke(_single(token));
        endpoint.deliver(SRC_EID);

        (uint256 price,) = oracleSink.getPrice(token);
        assertEq(price, (INITIAL_PRICE * 101) / 100);
    }

    function test_Deviation_belowThresholdDoesNotTrigger() public {
        priceRelay.poke(_single(token));
        endpoint.deliver(SRC_EID);

        // Move 0.1% (< 0.5% threshold) within heartbeat -> no relay.
        vm.warp(block.timestamp + 1);
        mockPriceProvider.setPrice((INITIAL_PRICE * 1001) / 1000);

        vm.expectRevert(IPriceRelay.NothingToRelay.selector);
        priceRelay.poke(_single(token));
    }

    // --- Peer authentication ----------------------------------------------

    function test_PeerRejection_nonPeerCannotUpdateSink() public {
        address rogue = makeAddr("rogue");
        bytes memory message = abi.encode(_single(token), _singlePrice(INITIAL_PRICE), uint64(block.timestamp));

        // Even when impersonating the endpoint, a non-peer source is rejected.
        vm.prank(address(endpoint));
        vm.expectRevert();
        oracleSink.lzReceive(
            Origin({ srcEid: SRC_EID, sender: _b32(rogue), nonce: 1 }), bytes32(0), message, address(0), ""
        );
    }

    function test_PeerRejection_nonEndpointCannotCallLzReceive() public {
        bytes memory message = abi.encode(_single(token), _singlePrice(INITIAL_PRICE), uint64(block.timestamp));
        vm.prank(makeAddr("rogue"));
        vm.expectRevert();
        oracleSink.lzReceive(
            Origin({ srcEid: SRC_EID, sender: _b32(address(priceRelay)), nonce: 1 }), bytes32(0), message, address(0), ""
        );
    }

    // --- Funding -----------------------------------------------------------

    function test_InsufficientBalance_pokeRevertsWhenUnfunded() public {
        (uint256 quoted,) = priceRelay.quote(_single(token));
        assertGt(quoted, 0, "expected non-zero LZ fee");

        address recipient = makeAddr("recipient");
        priceRelay.withdraw(recipient, address(priceRelay).balance);
        assertEq(address(priceRelay).balance, 0);

        vm.expectRevert(IPriceRelay.InsufficientBalance.selector);
        priceRelay.poke(_single(token));
    }

    function test_Withdraw_movesFunds() public {
        address recipient = makeAddr("recipient");
        priceRelay.withdraw(recipient, 1 ether);
        assertEq(recipient.balance, 1 ether);
    }

    function test_Withdraw_revertsWhenAmountExceedsBalance() public {
        vm.expectRevert(IPriceRelay.InsufficientBalance.selector);
        priceRelay.withdraw(makeAddr("recipient"), 1000 ether);
    }

    function test_Withdraw_onlyAdmin() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        priceRelay.withdraw(makeAddr("recipient"), 1 ether);
    }

    // --- Subscription gating ----------------------------------------------

    function test_Poke_revertsForUnsubscribedToken() public {
        vm.expectRevert(IPriceRelay.TokenNotSubscribed.selector);
        priceRelay.poke(_single(makeAddr("other")));
    }

    function test_Poke_isPermissionless() public {
        vm.prank(makeAddr("anyone"));
        priceRelay.poke(_single(token));
        endpoint.deliver(SRC_EID);

        (uint256 price,) = oracleSink.getPrice(token);
        assertEq(price, INITIAL_PRICE);
    }

    // --- OP PriceProvider consumes the sink --------------------------------

    function test_OpPriceProvider_readsRelayedPrice() public {
        priceRelay.poke(_single(token));
        endpoint.deliver(SRC_EID);

        address ppImpl = address(new PriceProvider());
        address[] memory emptyTokens = new address[](0);
        PriceProvider.Config[] memory emptyConfigs = new PriceProvider.Config[](0);
        PriceProvider opPriceProvider = PriceProvider(
            address(
                new UUPSProxy(
                    ppImpl,
                    abi.encodeWithSelector(
                        PriceProvider.initialize.selector, address(roleRegistry), emptyTokens, emptyConfigs
                    )
                )
            )
        );
        roleRegistry.grantRole(opPriceProvider.PRICE_PROVIDER_ADMIN_ROLE(), address(this));

        OracleSinkAggregatorAdapter adapter = new OracleSinkAggregatorAdapter(IOracleSink(address(oracleSink)), token);

        address[] memory tokens = _single(token);
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: address(adapter),
            priceFunctionCalldata: hex"",
            isChainlinkType: true,
            oraclePriceDecimals: 6,
            maxStaleness: 1 days,
            dataType: PriceProvider.ReturnType.Int256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });
        opPriceProvider.setTokenConfig(tokens, configs);

        assertEq(opPriceProvider.price(token), INITIAL_PRICE);
    }

    // --- OP PriceProvider consumes the sink DIRECTLY (no adapter) -----------

    /// @dev Deploys a bare OP PriceProvider with no token configs.
    function _deployOpPriceProvider() internal returns (PriceProvider opPriceProvider) {
        address ppImpl = address(new PriceProvider());
        address[] memory emptyTokens = new address[](0);
        PriceProvider.Config[] memory emptyConfigs = new PriceProvider.Config[](0);
        opPriceProvider = PriceProvider(
            address(
                new UUPSProxy(
                    ppImpl,
                    abi.encodeWithSelector(
                        PriceProvider.initialize.selector, address(roleRegistry), emptyTokens, emptyConfigs
                    )
                )
            )
        );
        roleRegistry.grantRole(opPriceProvider.PRICE_PROVIDER_ADMIN_ROLE(), address(this));
    }

    /// @dev Wires the OP PriceProvider to read the multi-token sink directly via the
    ///      calldata branch (token baked into priceFunctionCalldata), no adapter.
    function _configureSinkDirect(PriceProvider opPriceProvider) internal {
        address[] memory tokens = _single(token);
        PriceProvider.Config[] memory configs = new PriceProvider.Config[](1);
        configs[0] = PriceProvider.Config({
            oracle: address(oracleSink),
            priceFunctionCalldata: abi.encodeWithSelector(IOracleSink.price.selector, token),
            isChainlinkType: false,
            oraclePriceDecimals: 6,
            maxStaleness: 0, // unused on the calldata branch; sink enforces freshness
            dataType: PriceProvider.ReturnType.Uint256,
            isBaseTokenEth: false,
            isStableToken: false,
            isBaseTokenBtc: false
        });
        opPriceProvider.setTokenConfig(tokens, configs);
    }

    function test_DirectIntegration_priceProviderReadsSink() public {
        priceRelay.poke(_single(token));
        endpoint.deliver(SRC_EID);

        roleRegistry.grantRole(oracleSink.ORACLE_SINK_ADMIN_ROLE(), address(this));
        oracleSink.setMaxStaleness(token, 1 days);

        PriceProvider opPriceProvider = _deployOpPriceProvider();
        _configureSinkDirect(opPriceProvider);

        assertEq(opPriceProvider.price(token), INITIAL_PRICE);
    }

    function test_DirectIntegration_staleSinkRevertsInPriceProvider() public {
        priceRelay.poke(_single(token));
        endpoint.deliver(SRC_EID);

        roleRegistry.grantRole(oracleSink.ORACLE_SINK_ADMIN_ROLE(), address(this));
        oracleSink.setMaxStaleness(token, 1 hours);

        PriceProvider opPriceProvider = _deployOpPriceProvider();
        _configureSinkDirect(opPriceProvider);

        // Fresh read works.
        assertEq(opPriceProvider.price(token), INITIAL_PRICE);

        // Relay goes quiet: once the delivery ages past the sink window, the sink
        // reverts (PriceStale), which surfaces as PriceOracleFailed in PriceProvider.
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(PriceProvider.PriceOracleFailed.selector);
        opPriceProvider.price(token);
    }

    function test_DirectIntegration_noStalenessConfiguredNeverAgesOut() public {
        priceRelay.poke(_single(token));
        endpoint.deliver(SRC_EID);

        // maxStaleness left at 0 (disabled).
        PriceProvider opPriceProvider = _deployOpPriceProvider();
        _configureSinkDirect(opPriceProvider);

        vm.warp(block.timestamp + 3650 days);
        assertEq(opPriceProvider.price(token), INITIAL_PRICE);
    }

    function test_SetMaxStaleness_onlyAdmin() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        oracleSink.setMaxStaleness(token, 1 days);
    }
}
