// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626, IERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import { StockUnwrapper } from "../../src/stock-withdraw/StockUnwrapper.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { SafeTestSetup } from "../safe/SafeTestSetup.t.sol";

contract TestERC20 is ERC20 {
    constructor() ERC20("SPY Stock", "SPYx") { }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// @dev Minimal ERC-4626 wrapper standing in for WrappedBackedToken. `setPaused` mimics
///      Backed's transfer pause so we can test that a reverting redeem stays retryable.
contract TestWrapper is ERC4626 {
    bool public isPaused;
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Wrapped SPY Stock", "wSPYx") { }
    function setPaused(bool p) external { isPaused = p; }
    function _update(address from, address to, uint256 value) internal override {
        require(!isPaused, "WrappedBackedToken: token transfer while paused");
        super._update(from, to, value);
    }
}

/// @dev Stands in for the mainnet OFTAdapter: the unwrapper only calls `token()` on it.
contract AdapterStub {
    address public token;
    constructor(address _token) { token = _token; }
}

/// @dev Deterministic-address factory stub (real one is CREATE3; only the mapping matters here).
contract FactoryStub {
    function getDeterministicAddress(address sourceSafe) external pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("TradingSafe", sourceSafe)))));
    }
}

contract StockUnwrapperTest is SafeTestSetup {
    StockUnwrapper internal unwrapper;
    TestERC20 internal underlying;
    TestWrapper internal wrapper;
    AdapterStub internal adapter;
    FactoryStub internal factory;

    address internal lzEndpoint = makeAddr("lzEndpoint");
    address internal srcModule = makeAddr("stockWithdrawModule");
    address internal unwrapperAdmin = makeAddr("unwrapperAdmin");
    address internal sourceSafe = makeAddr("sourceSafe");
    address internal stockRecipient = makeAddr("stockRecipient");

    uint32 internal constant SRC_EID = 30111; // OP mainnet EID
    uint256 internal constant AMOUNT = 100e18;

    function setUp() public override {
        super.setUp();

        underlying = new TestERC20();
        wrapper = new TestWrapper(IERC20(address(underlying)));
        adapter = new AdapterStub(address(wrapper));
        factory = new FactoryStub();

        address impl = address(new StockUnwrapper());
        unwrapper = StockUnwrapper(address(new UUPSProxy(
            impl,
            abi.encodeWithSelector(
                StockUnwrapper.initialize.selector,
                address(roleRegistry), lzEndpoint, SRC_EID, srcModule, address(factory)
            )
        )));

        vm.startPrank(owner);
        roleRegistry.grantRole(unwrapper.STOCK_UNWRAPPER_ADMIN_ROLE(), unwrapperAdmin);
        vm.stopPrank();

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        bool[] memory registered = new bool[](1);
        registered[0] = true;
        vm.prank(unwrapperAdmin);
        unwrapper.configureAdapters(adapters, registered);

        // Simulate the OFTAdapter having credited wrapped tokens to the unwrapper
        // before lzCompose runs: deposit underlying 1:1, shares minted to the unwrapper.
        underlying.mint(address(this), AMOUNT);
        underlying.approve(address(wrapper), AMOUNT);
        wrapper.deposit(AMOUNT, address(unwrapper));
    }

    // ---- helpers ----

    function _message(uint256 amount, uint256 minReturn, uint256 deadline) internal view returns (bytes memory) {
        return _messageFrom(srcModule, amount, minReturn, deadline);
    }

    function _messageFrom(address composeSender, uint256 amount, uint256 minReturn, uint256 deadline) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encode(sourceSafe, stockRecipient, minReturn, deadline);
        return OFTComposeMsgCodec.encode(
            1, SRC_EID, amount,
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(composeSender), composeMsg)
        );
    }

    function _compose(bytes memory message) internal {
        vm.prank(lzEndpoint);
        unwrapper.lzCompose(address(adapter), bytes32(uint256(1)), message, address(0), "");
    }

    // ---- auth ----

    function test_lzCompose_revertsForNonEndpoint() public {
        bytes memory message = _message(AMOUNT, 1, block.timestamp + 1 hours);
        vm.expectRevert(StockUnwrapper.OnlyEndpoint.selector);
        unwrapper.lzCompose(address(adapter), bytes32(0), message, address(0), "");
    }

    function test_lzCompose_revertsForUnregisteredAdapter() public {
        bytes memory message = _message(AMOUNT, 1, block.timestamp + 1 hours);
        vm.prank(lzEndpoint);
        vm.expectRevert(StockUnwrapper.UnregisteredAdapter.selector);
        unwrapper.lzCompose(makeAddr("rogueAdapter"), bytes32(0), message, address(0), "");
    }

    function test_lzCompose_revertsForWrongSrcEid() public {
        bytes memory composeMsg = abi.encode(sourceSafe, stockRecipient, uint256(1), block.timestamp + 1 hours);
        bytes memory message = OFTComposeMsgCodec.encode(
            1, SRC_EID + 1, AMOUNT,
            abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(srcModule), composeMsg)
        );
        vm.prank(lzEndpoint);
        vm.expectRevert(StockUnwrapper.WrongSrcEid.selector);
        unwrapper.lzCompose(address(adapter), bytes32(0), message, address(0), "");
    }

    function test_lzCompose_revertsForWrongComposeSender() public {
        bytes memory message = _messageFrom(makeAddr("rogueModule"), AMOUNT, 1, block.timestamp + 1 hours);
        vm.prank(lzEndpoint);
        vm.expectRevert(StockUnwrapper.WrongComposeSender.selector);
        unwrapper.lzCompose(address(adapter), bytes32(0), message, address(0), "");
    }

    // ---- unwrap branch ----

    function test_lzCompose_unwrapsAndDeliversToRecipient() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.expectEmit(true, true, true, true, address(unwrapper));
        emit StockUnwrapper.StockUnwrapped(bytes32(uint256(1)), sourceSafe, stockRecipient, address(wrapper), AMOUNT, AMOUNT);
        _compose(_message(AMOUNT, AMOUNT, deadline));

        assertEq(underlying.balanceOf(stockRecipient), AMOUNT, "recipient got unwrapped stock");
        assertEq(wrapper.balanceOf(address(unwrapper)), 0, "shares burned");
    }

    function test_lzCompose_revertsWhenBelowMinReturn() public {
        // 1:1 rate: redeem returns exactly AMOUNT, so minReturn = AMOUNT + 1 must revert.
        bytes memory message = _message(AMOUNT, AMOUNT + 1, block.timestamp + 1 hours);
        vm.prank(lzEndpoint);
        vm.expectRevert(abi.encodeWithSelector(StockUnwrapper.InsufficientReturn.selector, AMOUNT, AMOUNT + 1));
        unwrapper.lzCompose(address(adapter), bytes32(0), message, address(0), "");
        // tokens still parked in the unwrapper → the LZ message is retryable
        assertEq(wrapper.balanceOf(address(unwrapper)), AMOUNT);
    }

    function test_lzCompose_revertsWhenWrapperPaused_thenSucceedsOnRetry() public {
        bytes memory message = _message(AMOUNT, AMOUNT, block.timestamp + 1 hours);
        wrapper.setPaused(true);
        vm.prank(lzEndpoint);
        vm.expectRevert(bytes("WrappedBackedToken: token transfer while paused"));
        unwrapper.lzCompose(address(adapter), bytes32(0), message, address(0), "");

        wrapper.setPaused(false);
        _compose(message); // retry with identical payload succeeds
        assertEq(underlying.balanceOf(stockRecipient), AMOUNT);
    }

    // ---- deadline branch ----

    function test_lzCompose_pastDeadline_deliversWrappedToTradingSafe() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory message = _message(AMOUNT, AMOUNT, deadline);
        vm.warp(deadline + 1);

        address tradingSafe = factory.getDeterministicAddress(sourceSafe);
        vm.expectEmit(true, true, true, true, address(unwrapper));
        emit StockUnwrapper.WrappedDeliveredToSafe(bytes32(uint256(1)), sourceSafe, tradingSafe, address(wrapper), AMOUNT);
        _compose(message);

        assertEq(wrapper.balanceOf(tradingSafe), AMOUNT, "wrapped delivered to safe");
        assertEq(underlying.balanceOf(stockRecipient), 0, "no unwrap happened");
    }

    function test_lzCompose_atDeadline_stillUnwraps() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory message = _message(AMOUNT, AMOUNT, deadline);
        vm.warp(deadline); // inclusive: block.timestamp == deadline is NOT expired
        _compose(message);
        assertEq(underlying.balanceOf(stockRecipient), AMOUNT);
    }

    function test_lzCompose_minReturnFail_thenDeadlineFallbackOnRetry() public {
        // The core lifecycle: minReturn revert → retry after deadline → wrapped to safe.
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory message = _message(AMOUNT, AMOUNT + 1, deadline);

        vm.prank(lzEndpoint);
        vm.expectRevert(abi.encodeWithSelector(StockUnwrapper.InsufficientReturn.selector, AMOUNT, AMOUNT + 1));
        unwrapper.lzCompose(address(adapter), bytes32(0), message, address(0), "");

        vm.warp(deadline + 1);
        _compose(message);
        assertEq(wrapper.balanceOf(factory.getDeterministicAddress(sourceSafe)), AMOUNT);
    }

    // ---- pause / rescue / config ----

    function test_lzCompose_revertsWhenPaused() public {
        vm.prank(pauser);
        unwrapper.pause();
        bytes memory message = _message(AMOUNT, AMOUNT, block.timestamp + 1 hours);
        vm.prank(lzEndpoint);
        vm.expectRevert(); // PausableUpgradeable.EnforcedPause
        unwrapper.lzCompose(address(adapter), bytes32(0), message, address(0), "");
    }

    function test_rescueTokens_adminOnly() public {
        vm.expectRevert(StockUnwrapper.OnlyAdmin.selector);
        unwrapper.rescueTokens(address(wrapper), owner, AMOUNT);

        vm.prank(unwrapperAdmin);
        unwrapper.rescueTokens(address(wrapper), owner, AMOUNT);
        assertEq(wrapper.balanceOf(owner), AMOUNT);
    }

    function test_configureAdapters_adminOnly() public {
        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        bool[] memory registered = new bool[](1);
        vm.expectRevert(StockUnwrapper.OnlyAdmin.selector);
        unwrapper.configureAdapters(adapters, registered);
    }

    function test_configureAdapters_validatesInput() public {
        address[] memory adapters = new address[](1);
        adapters[0] = address(0);
        bool[] memory registered = new bool[](1);
        registered[0] = true;
        vm.prank(unwrapperAdmin);
        vm.expectRevert(StockUnwrapper.InvalidInput.selector);
        unwrapper.configureAdapters(adapters, registered);
    }

    function test_setSrcModule_adminOnlyAndStores() public {
        address newModule = makeAddr("newModule");
        vm.expectRevert(StockUnwrapper.OnlyAdmin.selector);
        unwrapper.setSrcModule(newModule);

        vm.prank(unwrapperAdmin);
        unwrapper.setSrcModule(newModule);
        assertEq(unwrapper.getSrcModule(), OFTComposeMsgCodec.addressToBytes32(newModule));
    }

    function test_initialize_revertsOnZeroInput() public {
        address impl = address(new StockUnwrapper());
        vm.expectRevert(StockUnwrapper.InvalidInput.selector);
        new UUPSProxy(impl, abi.encodeWithSelector(
            StockUnwrapper.initialize.selector,
            address(roleRegistry), address(0), SRC_EID, srcModule, address(factory)
        ));
    }
}
