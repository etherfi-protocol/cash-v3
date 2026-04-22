// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Origin } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";

import { SafeTestSetup } from "../safe/SafeTestSetup.t.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RecoveryModule } from "../../src/modules/recovery/RecoveryModule.sol";
import { TopUpDispatcher } from "../../src/top-up/TopUpDispatcher.sol";
import { TopUpV2 } from "../../src/top-up/TopUpV2.sol";
import { RecoveryMessageLib } from "../../src/libraries/RecoveryMessageLib.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { LZEndpointMock } from "../mocks/LZEndpointMock.sol";

/**
 * @title RecoveryE2E
 * @notice Stitches the full recovery flow in a single EVM: Safe owners sign the recovery
 *         request on the OP side, the LayerZero send is captured by the source endpoint mock,
 *         and the captured message is then hand-delivered to the dispatcher's `lzReceive` on
 *         the destination side. Asserts that funds at the destination-side TopUpV2 (etched
 *         onto the Safe's CREATE3-parity address) are transferred to the user's recipient.
 * @dev This is not a real dual-fork test — the LZ message bus is simulated via our mock
 *      endpoint's `lastSendArgs`. The parts this covers that the unit tests don't:
 *      (1) the payload encoding produced by `executeRecovery` decodes cleanly on the dispatcher,
 *      (2) the dispatcher's forwarding call lands on a TopUpV2 with matching `DISPATCHER`,
 *      (3) a real Safe multisig signs the request digest end-to-end.
 */
contract RecoveryE2ETest is SafeTestSetup {
    RecoveryModule public module;
    TopUpDispatcher public dispatcher;
    LZEndpointMock public srcEndpoint; // OP
    LZEndpointMock public dstEndpoint; // destination (e.g. Arbitrum)
    MockERC20 public token;

    uint32 public constant OP_EID = 30_111;
    uint32 public constant ARB_EID = 30_110;
    address public recipient = makeAddr("recipient");
    address public weth = makeAddr("weth"); // unused by executeRecovery, but TopUp needs one

    function setUp() public override {
        super.setUp();

        // ── Source (OP) wiring ────────────────────────────────────────────────────────────
        srcEndpoint = new LZEndpointMock();

        vm.startPrank(owner);
        address moduleImpl = address(new RecoveryModule(address(dataProvider), address(srcEndpoint)));
        module = RecoveryModule(address(new UUPSProxy(
            moduleImpl,
            abi.encodeWithSelector(RecoveryModule.initialize.selector, owner)
        )));

        // whitelist + attach the module to the Safe
        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        dataProvider.configureModules(modules, shouldWhitelist);
        bytes[] memory moduleSetupData = new bytes[](1);
        moduleSetupData[0] = "";
        _configureModules(modules, shouldWhitelist, moduleSetupData);

        // ── Destination (Arb) wiring ──────────────────────────────────────────────────────
        dstEndpoint = new LZEndpointMock();
        address dispatcherImpl = address(new TopUpDispatcher(
            address(dstEndpoint),
            OP_EID,
            address(roleRegistry)
        ));
        dispatcher = TopUpDispatcher(address(new UUPSProxy(
            dispatcherImpl,
            abi.encodeWithSelector(TopUpDispatcher.initialize.selector, owner)
        )));

        // ── Peer both sides ──────────────────────────────────────────────────────────────
        module.setPeer(ARB_EID, bytes32(uint256(uint160(address(dispatcher)))));
        dispatcher.setPeer(OP_EID, bytes32(uint256(uint160(address(module)))));

        vm.stopPrank();

        token = new MockERC20("Mock", "MOCK", 18);
    }

    function test_e2e_opToArb_happyPath() public {
        uint256 amount = 42e18;

        // ── Phase 1: source side ─────────────────────────────────────────────────────────
        // Safe owners sign the recovery request digest
        uint256 nonce = module.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(module),
            nonce,
            address(safe),
            address(token),
            amount,
            recipient,
            ARB_EID
        ));
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(owner1Pk, digest);
        sigs[1] = _sign(owner2Pk, digest);

        bytes32 id = module.requestRecovery(address(safe), address(token), amount, recipient, ARB_EID, signers, sigs);

        skip(3 days + 1);

        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        module.executeRecovery{value: 1e15}(address(safe), id, "");

        // Pull the LZ message captured by the source endpoint mock
        (uint32 dstEid, bytes memory message) = srcEndpoint.lastSendArgs();
        assertEq(uint256(dstEid), uint256(ARB_EID), "dstEid mismatch");

        // ── Phase 2: destination side ────────────────────────────────────────────────────
        // Etch TopUpV2 runtime (DISPATCHER immutable baked in) onto the Safe's address so
        // `p.safe` resolves to a real TopUpV2 on the destination, preserving CREATE3 parity.
        TopUpV2 topUpImpl = new TopUpV2(weth, address(dispatcher));
        vm.etch(address(safe), address(topUpImpl).code);
        token.mint(address(safe), 100e18);

        Origin memory origin = Origin({
            srcEid: OP_EID,
            sender: bytes32(uint256(uint160(address(module)))),
            nonce: 1
        });

        vm.prank(address(dstEndpoint));
        dispatcher.lzReceive(origin, bytes32(uint256(1)), message, address(0), "");

        assertEq(token.balanceOf(recipient), amount, "recipient balance mismatch");
        assertEq(token.balanceOf(address(safe)), 100e18 - amount, "topup balance mismatch");
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
