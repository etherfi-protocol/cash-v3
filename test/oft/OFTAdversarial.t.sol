// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { PacketV1Codec } from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";
import { OAppReceiverUpgradeable } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import { stdError } from "forge-std/StdError.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { EtherFiOFTAdapter } from "../../src/oft/EtherFiOFTAdapter.sol";
import { EtherFiShadowOFT } from "../../src/oft/EtherFiShadowOFT.sol";
import { OFTCrossChainSetup } from "./OFTCrossChainSetup.t.sol";

/**
 * @title OFTAdversarialTest
 * @notice Adversarial / negative cross-chain. Covers the inbound trust boundary (only the
 *         endpoint and only the registered peer may drive `lzReceive`), replay protection at the
 *         endpoint, owner-gated peer/delegate wiring, the proxy re-initialization guard (closing
 *         the previously-untested adapter gap), and reentrancy on the lock path.
 */
contract OFTAdversarialTest is OFTCrossChainSetup {
    using OptionsBuilder for bytes;
    using PacketV1Codec for bytes;

    function setUp() public override {
        super.setUp();
        _deployPair(8);
    }

    /// @dev External so PacketV1Codec (calldata-only) can read the queued packet bytes.
    function decodePacket(bytes calldata p) external pure returns (uint32 srcEid, bytes32 sender, uint64 nonce, bytes32 guid, bytes memory message) {
        return (p.srcEid(), p.sender(), p.nonce(), p.guid(), p.message());
    }

    // ----------------------------------------------------------------- inbound peer enforcement

    address internal attacker = makeAddr("attacker");

    // Anyone other than the local endpoint calling lzReceive directly is rejected.
    function test_lzReceive_revertsForNonEndpointCaller() public {
        Origin memory o = Origin({ srcEid: A_EID, sender: _b32(address(adapter)), nonce: 1 });
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiverUpgradeable.OnlyEndpoint.selector, attacker));
        shadow.lzReceive(o, bytes32(0), "", address(0), "");
    }

    // A message whose srcEid is correct but sender is NOT the wired peer is rejected.
    function test_lzReceive_revertsForNonPeerSender() public {
        Origin memory o = Origin({ srcEid: A_EID, sender: _b32(attacker), nonce: 1 });
        vm.prank(endpoints[B_EID]);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, A_EID, _b32(attacker)));
        shadow.lzReceive(o, bytes32(0), "", address(0), "");
    }

    // A message from an eid with no configured peer is rejected (NoPeer), even from the endpoint.
    function test_lzReceive_revertsForUnknownSrcEid() public {
        uint32 unknownEid = 4444;
        Origin memory o = Origin({ srcEid: unknownEid, sender: _b32(address(adapter)), nonce: 1 });
        vm.prank(endpoints[B_EID]);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, unknownEid));
        shadow.lzReceive(o, bytes32(0), "", address(0), "");
    }

    // ----------------------------------------------------------------- replay protection

    /**
     * Replaying an already-executed inbound packet through the endpoint does not double-mint:
     * the endpoint clears the payload hash on execution, so a second lzReceive for the same
     * nonce reverts and the iTOKEN supply is unchanged.
     */
    function test_replay_noDoubleMint() public {
        uint256 amount = 500e8;
        underlying.mint(alice, amount);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory sp = SendParam(B_EID, _b32(alice), amount, 0, options, "", "");
        MessagingFee memory fee = adapter.quoteSend(sp, false);

        vm.startPrank(alice);
        underlying.approve(address(adapter), amount);
        adapter.send{ value: fee.nativeFee }(sp, fee, payable(alice));
        vm.stopPrank();

        // Grab the in-flight packet before delivery so we can attempt to re-execute it.
        bytes memory packet = getNextInflightPacket(uint16(B_EID), _b32(address(shadow)));
        (uint32 srcEid, bytes32 sender, uint64 nonce, bytes32 guid, bytes memory message) = this.decodePacket(packet);
        Origin memory o = Origin({ srcEid: srcEid, sender: sender, nonce: nonce });

        // First delivery mints exactly `amount`.
        verifyPackets(B_EID, _b32(address(shadow)));
        assertEq(shadow.totalSupply(), amount);
        assertEq(shadow.balanceOf(alice), amount);

        // Replaying the same nonce through the endpoint reverts; supply stays put.
        vm.expectRevert();
        ILayerZeroEndpointV2(endpoints[B_EID]).lzReceive(o, address(shadow), guid, message, "");
        assertEq(shadow.totalSupply(), amount, "replay double-minted");
    }

    // ----------------------------------------------------------------- owner-gated wiring

    function test_setPeer_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        adapter.setPeer(B_EID, _b32(attacker));
    }

    function test_setDelegate_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        adapter.setDelegate(attacker);
    }

    // The wired owner CAN re-point a peer (sanity that the gate is the only obstacle).
    function test_setPeer_ownerSucceeds() public {
        address newPeer = makeAddr("newPeer");
        vm.prank(delegate);
        adapter.setPeer(B_EID, _b32(newPeer));
        assertEq(adapter.peers(B_EID), _b32(newPeer));
    }

    // ----------------------------------------------------------------- re-initialization guard

    /**
     * The adapter's reinit guard was previously untested (only the shadow's was). A factory-deployed,
     * already-initialized adapter proxy cannot be re-initialized.
     */
    function test_adapter_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        adapter.initialize(address(underlying), delegate);
    }

    function test_shadow_cannotReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        shadow.initialize("x", "x", 8, delegate);
    }

    // ----------------------------------------------------------------- reentrancy on lock path

    /**
     * A malicious underlying that re-enters adapter.send() mid-transfer cannot corrupt accounting.
     * The re-entrant send triggers a second lock whose transferFrom pulls from the TOKEN contract
     * (the nested send's caller), which holds no allowance/balance — so it underflows and the whole
     * outer send reverts atomically: nothing is locked and nothing is minted on the destination.
     *
     * The token is funded with ETH so the nested send can pay its messaging fee; this isolates the
     * failure to the genuine double-spend path rather than incidental gas/fee starvation.
     */
    function test_reentrancy_onLock_isContained() public {
        ReentrantToken evil = new ReentrantToken();
        // Deploy a dedicated adapter for the evil token via the factory.
        vm.prank(factoryAdmin);
        EtherFiOFTAdapter evilAdapter = EtherFiOFTAdapter(adapterFactory.deployAdapter(keccak256("evil"), address(evil), delegate));
        vm.startPrank(delegate);
        evilAdapter.setPeer(B_EID, _b32(address(shadow)));
        vm.stopPrank();

        uint256 amount = 100e8;
        evil.mint(alice, amount);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200_000, 0);
        SendParam memory sp = SendParam(B_EID, _b32(alice), amount, 0, options, "", "");
        MessagingFee memory fee = evilAdapter.quoteSend(sp, false);

        evil.arm(address(evilAdapter), sp, fee);
        vm.deal(address(evil), 100 ether); // so the nested send isn't blocked by fee starvation

        vm.startPrank(alice);
        evil.approve(address(evilAdapter), amount);
        // the re-entrant lock double-spends an allowance the token contract doesn't hold -> underflow
        vm.expectRevert(stdError.arithmeticError);
        evilAdapter.send{ value: fee.nativeFee }(sp, fee, payable(alice));
        vm.stopPrank();

        assertEq(evil.balanceOf(address(evilAdapter)), 0, "tokens locked despite reverting send");
        assertEq(shadow.totalSupply(), 0, "iTOKEN minted despite reverting send");
    }
}

/**
 *  Underlying that re-enters the adapter's send() during the lock transferFrom.
 */
contract ReentrantToken {
    string public name = "Evil";
    string public symbol = "EVIL";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bool internal armed;
    address internal adapter;
    SendParam internal sp;
    MessagingFee internal fee;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function arm(address _adapter, SendParam memory _sp, MessagingFee memory _fee) external {
        armed = true;
        adapter = _adapter;
        sp = _sp;
        fee = _fee;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (armed) {
            armed = false; // re-enter exactly once
            EtherFiOFTAdapter(adapter).send{ value: fee.nativeFee }(sp, fee, payable(from));
        }
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}
