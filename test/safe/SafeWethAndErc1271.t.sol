// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IWETH } from "../../src/interfaces/IWETH.sol";
import { EtherFiSafe, SafeTestSetup } from "./SafeTestSetup.t.sol";

contract SafeWethAndErc1271Test is SafeTestSetup {
    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant INVALID = 0xffffffff;

    address weth;

    function setUp() public override {
        super.setUp();
        weth = chainConfig.weth;
    }

    // ── native ETH ──────────────────────────────────────────────────────────

    function test_receive_wrapsIncomingEth() public {
        (bool ok,) = address(safe).call{ value: 1 ether }("");

        assertTrue(ok);
        assertEq(address(safe).balance, 0);
        assertEq(IERC20(weth).balanceOf(address(safe)), 1 ether);
    }

    function test_wrapEth_sweepsBalanceThatBypassedReceive() public {
        deal(address(safe), 3 ether);

        safe.wrapEth();

        assertEq(address(safe).balance, 0);
        assertEq(IERC20(weth).balanceOf(address(safe)), 3 ether);
    }

    function test_wrapEth_isNoOpOnZeroBalance() public {
        safe.wrapEth();
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);
    }

    /// @dev A callee reached mid-batch must not be able to wrap the native ETH the batch still needs.
    function test_wrapEth_isNoOpMidBatch() public {
        WrapCaller caller = new WrapCaller();
        deal(address(safe), 1 ether);

        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = address(caller);
        data[0] = abi.encodeCall(WrapCaller.wrap, (address(safe)));

        vm.prank(address(cashModule));
        safe.execTransactionFromModule(to, new uint256[](1), data);

        assertEq(address(safe).balance, 1 ether);
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);
    }

    /// @dev WETH9 unwraps on a 2300-gas stipend, far too little to re-wrap — AaveV3Module's ETH paths would revert.
    function test_receive_skipsWethSoUnwrapDoesNotRevert() public {
        deal(weth, address(safe), 2 ether);

        address[] memory to = new address[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = weth;
        data[0] = abi.encodeWithSelector(IWETH.withdraw.selector, 2 ether);

        vm.prank(address(cashModule));
        safe.execTransactionFromModule(to, new uint256[](1), data);

        assertEq(address(safe).balance, 2 ether);
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);

        safe.wrapEth();
        assertEq(IERC20(weth).balanceOf(address(safe)), 2 ether);
    }

    /// @dev EnsoSwapModule pre-funds its native fee, then spends it as call value in the batch that follows.
    function test_receive_passesThroughModulePreFunding() public {
        vm.deal(address(cashModule), 1 ether);

        vm.prank(address(cashModule));
        (bool ok,) = address(safe).call{ value: 1 ether }("");

        assertTrue(ok);
        assertEq(address(safe).balance, 1 ether);
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);
    }

    /// @dev OpenOceanSwapModule reads its ETH output as a native balance delta across the batch.
    function test_receive_passesThroughEthArrivingMidBatch() public {
        EthBouncer bouncer = new EthBouncer();
        deal(address(safe), 1 ether);

        address[] memory to = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory data = new bytes[](1);
        to[0] = address(bouncer);
        values[0] = 1 ether;
        data[0] = abi.encodeCall(EthBouncer.bounce, ());

        assertFalse(safe.inModuleBatch());

        vm.prank(address(cashModule));
        safe.execTransactionFromModule(to, values, data);

        assertFalse(safe.inModuleBatch());
        assertEq(address(safe).balance, 1 ether);
        assertEq(IERC20(weth).balanceOf(address(safe)), 0);
    }

    /// @dev Known ceiling: nothing here stipend-sends to a safe, and `wrapEth` recovers it if anything does.
    function test_receive_revertsOnStipendSendFromNonWeth() public {
        StipendSender sender = new StipendSender();
        vm.deal(address(sender), 1 ether);

        vm.expectRevert();
        sender.send(payable(address(safe)), 1 ether);
    }

    // ── ERC-1271 ────────────────────────────────────────────────────────────

    function test_isValidSignature_acceptsOwnerSignedMessage() public view {
        bytes memory message = "ether.fi safe ownership proof";
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(message);

        assertEq(safe.isValidSignature(hash, _blob(message, hash)), MAGIC);
    }

    function test_isValidSignature_rejectsMismatchedPreimage() public view {
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(bytes("the real message"));

        assertEq(safe.isValidSignature(hash, _blob(bytes("a different message"), hash)), INVALID);
    }

    /// @dev The LendGateway invariant. Even holding threshold keys and supplying the digest's genuine keccak
    ///      preimage, the EIP-191 prefix makes it unreachable. Same argument covers Permit2 and Seaport.
    function test_isValidSignature_rejectsForeignEip712Digest() public view {
        bytes32 foreignDomain = keccak256("AaveV4Spoke");
        bytes32 structHash = keccak256("SetUserPositionManagers(address user,...)");
        bytes32 foreignDigest = keccak256(abi.encodePacked(hex"1901", foreignDomain, structHash));

        bytes memory preimage = abi.encodePacked(hex"1901", foreignDomain, structHash);
        assertEq(keccak256(preimage), foreignDigest, "preimage is genuine under plain keccak");

        assertEq(safe.isValidSignature(foreignDigest, _blob(preimage, foreignDigest)), INVALID);
    }

    /// @dev Builds a blob carrying `message` plus two owner signatures over `hash` wrapped in the safe's domain.
    function _blob(bytes memory message, bytes32 hash) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), keccak256(abi.encode(safe.SAFE_MESSAGE_TYPEHASH(), hash))));

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        return abi.encode(message, signers, signatures);
    }
}

contract StipendSender {
    function send(address payable to, uint256 amount) external {
        to.transfer(amount);
    }
}

contract WrapCaller {
    function wrap(address safe) external {
        EtherFiSafe(payable(safe)).wrapEth();
    }
}

contract EthBouncer {
    function bounce() external payable {
        (bool ok,) = msg.sender.call{ value: msg.value }("");
        require(ok, "bounce failed");
    }
}
