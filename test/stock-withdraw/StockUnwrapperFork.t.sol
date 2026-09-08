// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";

contract AdapterStub {
    address public token;
    constructor(address _token) { token = _token; }
}

/// @dev Permissive registry so the fork test can exercise the unwrapper without granting
///      roles on the live mainnet RoleRegistry.
contract RoleRegistryStub {
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
    function onlyPauser(address) external pure { }
    function onlyUnpauser(address) external pure { }
    function onlyUpgrader(address) external pure { }
}

interface IWrappedBacked {
    function sanctionsList() external view returns (address);
}

interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}

/// @dev Fork test against the REAL wSPYx Backed wrapper: proves the ERC-4626 redeem
///      integration, decimals, and both compose branches against production bytecode.
///      Requires MAINNET_RPC env var; skipped otherwise.
contract StockUnwrapperForkTest is Test {
    address internal constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    uint32 internal constant OP_EID = 30111;

    StockUnwrapper internal unwrapper;
    AdapterStub internal adapter;
    address internal lzEndpoint = makeAddr("lzEndpoint");
    address internal srcModule = makeAddr("srcModule");
    address internal sourceSafe = makeAddr("sourceSafe");
    address internal stockRecipient = makeAddr("stockRecipient");

    uint256 internal amount;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);

        adapter = new AdapterStub(WSPYX);
        RoleRegistryStub registry = new RoleRegistryStub();

        // Full config at initialize, including the adapter allowlist.
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        bool[] memory registered = new bool[](1);
        registered[0] = true;

        address impl = address(new StockUnwrapper());
        unwrapper = StockUnwrapper(address(new UUPSProxy(
            impl,
            abi.encodeWithSelector(
                StockUnwrapper.initialize.selector,
                address(registry), lzEndpoint, OP_EID, srcModule, adapters, registered
            )
        )));

        amount = 10 ** IERC20Metadata(WSPYX).decimals(); // 1 wSPYx
        deal(WSPYX, address(unwrapper), amount);
    }

    function _message(uint256 _amount, uint256 minReturn, uint256 deadline) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encode(sourceSafe, stockRecipient, minReturn, deadline);
        return OFTComposeMsgCodec.encode(
            1, OP_EID, _amount,
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(srcModule), composeMsg)
        );
    }

    function test_redeem_realWrapper() public {
        uint256 expectedAssets = IERC4626(WSPYX).previewRedeem(amount);
        assertGt(expectedAssets, 0, "wrapper quotes a real redeem");

        vm.prank(lzEndpoint);
        unwrapper.lzCompose(address(adapter), bytes32(0), _message(amount, expectedAssets, block.timestamp + 1 hours), address(0), "");

        address underlying = IERC4626(WSPYX).asset();
        assertEq(IERC20(underlying).balanceOf(stockRecipient), expectedAssets, "recipient received real SPYx");
        assertEq(IERC20(WSPYX).balanceOf(address(unwrapper)), 0, "wrapper shares burned");
    }

    function test_redeem_realWrapper_revertsBelowMinReturn() public {
        uint256 expectedAssets = IERC4626(WSPYX).previewRedeem(amount);

        vm.prank(lzEndpoint);
        vm.expectRevert(abi.encodeWithSelector(StockUnwrapper.InsufficientReturn.selector, expectedAssets, expectedAssets + 1));
        unwrapper.lzCompose(address(adapter), bytes32(0), _message(amount, expectedAssets + 1, block.timestamp + 1 hours), address(0), "");
    }

    function test_pastDeadline_deliversWrappedToSourceSafe() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory message = _message(amount, 1, deadline);
        vm.warp(deadline + 1);

        vm.prank(lzEndpoint);
        unwrapper.lzCompose(address(adapter), bytes32(0), message, address(0), "");

        assertEq(IERC20(WSPYX).balanceOf(sourceSafe), amount, "wrapped delivered to the safe address");
    }

    function test_sanctionedHolder_makesRedeemRevert_provingRetryPath() public {
        // Sanction the unwrapper on the Chainalysis list: the share burn inside redeem()
        // then reverts, exactly the "compose reverts → LZ retry queue" premise. The current
        // wrapper implementation resolves the list via the UNDERLYING Backed token.
        address sanctions = IWrappedBacked(IERC4626(WSPYX).asset()).sanctionsList();
        vm.mockCall(sanctions, abi.encodeWithSelector(ISanctionsList.isSanctioned.selector, address(unwrapper)), abi.encode(true));

        vm.prank(lzEndpoint);
        vm.expectRevert(bytes("WrappedBackedToken: sender is sanctioned"));
        unwrapper.lzCompose(address(adapter), bytes32(0), _message(amount, 1, block.timestamp + 1 hours), address(0), "");

        assertEq(IERC20(WSPYX).balanceOf(address(unwrapper)), amount, "tokens still parked, message retryable");
    }
}
