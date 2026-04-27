// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { IRecoveryModule } from "../../../../src/interfaces/IRecoveryModule.sol";
import { RecoveryModule } from "../../../../src/modules/recovery/RecoveryModule.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { MockERC20 } from "../../../../src/mocks/MockERC20.sol";
import { LZEndpointMock } from "../../../mocks/LZEndpointMock.sol";

contract RecoveryModuleTest is SafeTestSetup {
    RecoveryModule public module;
    LZEndpointMock public lzEndpoint;
    MockERC20 public token;
    address public safeAddr;

    address public dispatcher = makeAddr("dispatcher");
    uint32 public constant ARB_EID = 30_110;

    function setUp() public override {
        super.setUp();

        safeAddr = address(safe);

        vm.startPrank(owner);

        lzEndpoint = new LZEndpointMock();

        module = new RecoveryModule(address(dataProvider), address(lzEndpoint), owner);

        module.setPeer(ARB_EID, bytes32(uint256(uint160(dispatcher))));

        address[] memory modules = new address[](1);
        modules[0] = address(module);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        dataProvider.configureModules(modules, shouldWhitelist);

        bytes[] memory moduleSetupData = new bytes[](1);
        moduleSetupData[0] = "";
        _configureModules(modules, shouldWhitelist, moduleSetupData);

        token = new MockERC20("Mock", "MOCK", 18);

        vm.stopPrank();
    }

    function test_recover_happyPath_emitsRecoverySentAndDispatchesLz() public {
        uint256 amount = 1e18;
        address recipient = makeAddr("recipient");
        uint32 destEid = ARB_EID;

        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), amount, recipient, destEid);

        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        bytes32 lzGuid = module.recover{value: 1e15}(
            safeAddr, address(token), amount, recipient, destEid, "", signers, sigs
        );
        assertTrue(lzGuid != bytes32(0), "guid should be non-zero");

        (uint32 dstEid, bytes memory message) = lzEndpoint.lastSendArgs();
        assertEq(uint256(dstEid), uint256(destEid), "destEid mismatch");
        (address payloadSafe, address payloadToken, uint256 payloadAmount, address payloadRecipient) =
            abi.decode(message, (address, address, uint256, address));
        assertEq(payloadSafe, safeAddr, "payload safe mismatch");
        assertEq(payloadToken, address(token), "payload token mismatch");
        assertEq(payloadAmount, amount, "payload amount mismatch");
        assertEq(payloadRecipient, recipient, "payload recipient mismatch");
    }

    function test_recover_revertsIfTokenZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(0), 1e18, makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(IRecoveryModule.InvalidToken.selector);
        module.recover{value: 1e15}(safeAddr, address(0), 1e18, makeAddr("recipient"), ARB_EID, "", signers, sigs);
    }

    function test_recover_revertsIfAmountZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), 0, makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(IRecoveryModule.InvalidAmount.selector);
        module.recover{value: 1e15}(safeAddr, address(token), 0, makeAddr("recipient"), ARB_EID, "", signers, sigs);
    }

    function test_recover_revertsIfRecipientZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), 1e18, address(0), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(IRecoveryModule.InvalidRecipient.selector);
        module.recover{value: 1e15}(safeAddr, address(token), 1e18, address(0), ARB_EID, "", signers, sigs);
    }

    function test_recover_revertsIfPeerUnset() public {
        vm.prank(module.owner());
        module.setPeer(ARB_EID, bytes32(0));

        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), 1e18, makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(IRecoveryModule.InvalidDestEid.selector);
        module.recover{value: 1e15}(safeAddr, address(token), 1e18, makeAddr("recipient"), ARB_EID, "", signers, sigs);
    }

    function test_recover_revertsIfBadSignature() public {
        // Sign over the right digest but submit with the wrong amount — `checkSignatures` rejects.
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), 1e18, makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.recover{value: 1e15}(safeAddr, address(token), 2e18, makeAddr("recipient"), ARB_EID, "", signers, sigs);
    }

    function test_recover_digestReplayReverts() public {
        address recipient = makeAddr("recipient");
        uint256 amount = 1e18;
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), amount, recipient, ARB_EID);

        vm.deal(owner1, 1 ether);
        vm.startPrank(owner1);
        module.recover{value: 1e15}(safeAddr, address(token), amount, recipient, ARB_EID, "", signers, sigs);

        // Replay with same sigs — nonce has advanced, digest no longer matches.
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.recover{value: 1e15}(safeAddr, address(token), amount, recipient, ARB_EID, "", signers, sigs);
        vm.stopPrank();
    }

    function test_recover_revertsIfLzOptionsMismatch() public {
        // Owners sign for one set of lzOptions; submitter swaps in different options.
        // Digest binding on `keccak256(lzOptions)` must reject this.
        bytes memory signedOptions = hex"00030100110100000000000000000000000000030d40";
        bytes memory submittedOptions = hex"00030100110100000000000000000000000000000001";

        (address[] memory signers, bytes[] memory sigs) =
            _signRecoverWithOptions(address(token), 1e18, makeAddr("recipient"), ARB_EID, signedOptions);

        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.recover{value: 1e15}(
            safeAddr, address(token), 1e18, makeAddr("recipient"), ARB_EID, submittedOptions, signers, sigs
        );
    }

    function test_recover_revertsWhenPaused() public {
        vm.prank(pauser);
        module.pause();

        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), 1e18, makeAddr("recipient"), ARB_EID);
        vm.deal(owner1, 1 ether);
        vm.prank(owner1);
        vm.expectRevert();
        module.recover{value: 1e15}(safeAddr, address(token), 1e18, makeAddr("recipient"), ARB_EID, "", signers, sigs);
    }

    function test_pause_onlyPauser() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        module.pause();
    }

    function test_quote_returnsEndpointQuote() public {
        // LZEndpointMock returns (0, 0); the call path is what we're exercising.
        uint256 fee = module.quote(safeAddr, address(token), 1e18, makeAddr("recipient"), ARB_EID, "");
        assertEq(fee, 0, "mock endpoint returns zero fee");
    }

    function _signRecover(address token_, uint256 amount, address recipient, uint32 destEid)
        internal
        view
        returns (address[] memory signers, bytes[] memory sigs)
    {
        return _signRecoverWithOptions(token_, amount, recipient, destEid, "");
    }

    function _signRecoverWithOptions(
        address token_,
        uint256 amount,
        address recipient,
        uint32 destEid,
        bytes memory lzOptions
    ) internal view returns (address[] memory signers, bytes[] memory sigs) {
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(module),
            module.getNonce(safeAddr),
            safeAddr,
            token_,
            amount,
            recipient,
            destEid,
            keccak256(lzOptions)
        ));

        signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);
    }

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
