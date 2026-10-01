// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC4626Mock } from "@openzeppelin/contracts/mocks/token/ERC4626Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { IBackedCCIPBridge } from "../../src/interfaces/IBackedCCIPBridge.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { StockBridgeWithdrawModule } from "../../src/stock-withdraw/StockBridgeWithdrawModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { SafeTestSetup } from "../safe/SafeTestSetup.t.sol";

/// @dev Backed bridge stand-in: pulls the token from the caller like custody would, charges a flat native fee and
///      records the last send
contract BridgeMock is IBackedCCIPBridge {
    uint256 public fee = 0.001 ether;
    mapping(address => uint64) public tokenIds;
    uint256 public sends;
    uint64 public lastSelector;
    bytes32 public lastReceiver;
    address public lastToken;
    uint256 public lastAmount;

    function register(address token, uint64 id) external {
        tokenIds[token] = id;
    }

    function setFee(uint256 f) external {
        fee = f;
    }

    function send(uint64 selector, bytes32 receiver, address token, uint256 amount, bytes calldata) external payable returns (bytes32) {
        require(msg.value == fee, "BridgeMock: bad fee");
        require(tokenIds[token] != 0, "BridgeMock: token");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        sends++;
        lastSelector = selector;
        lastReceiver = receiver;
        lastToken = token;
        lastAmount = amount;
        return keccak256(abi.encode(sends));
    }

    function getDeliveryFeeCost(uint64, bytes32, address, uint256, bytes calldata) external view returns (uint256) {
        return fee;
    }
}

contract StockBridgeWithdrawModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    StockBridgeWithdrawModule internal module;
    BridgeMock internal bridge;
    MockERC20 internal raw;
    ERC4626Mock internal wrapper;

    address internal keeper = makeAddr("keeper");
    address internal moduleAdmin = makeAddr("moduleAdmin");
    address internal recipient = makeAddr("recipient");

    uint64 internal constant ETH_SELECTOR = 5_009_297_550_715_157_269;
    uint256 internal constant AMOUNT = 100e18;
    uint256 internal constant KEEPER_ETH = 1 ether;

    address internal constant BACKED_BRIDGE = 0x9eC0e4A4c411493773E01e2ABF4D42395788846b;
    address internal constant BACKED_CUSTODY = 0x5F7A4c11bde4f218f0025Ef444c369d838ffa2aD;
    address internal constant SPYX = 0x90A2a4c76b5D8c0bc892A69EA28Aa775a8f2dD48;
    address internal constant WSPYX = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;

    function setUp() public override {
        super.setUp();

        bridge = new BridgeMock();
        raw = new MockERC20("SPYx", "SPYx", 18);
        wrapper = new ERC4626Mock(address(raw));
        bridge.register(address(raw), 1);
        bridge.register(SPYX, 2);

        address impl = address(new StockBridgeWithdrawModule(address(dataProvider)));
        module = StockBridgeWithdrawModule(address(new UUPSProxy(impl, abi.encodeCall(StockBridgeWithdrawModule.initialize, (address(roleRegistry), address(bridge), ETH_SELECTOR)))));

        address[] memory mods = new address[](1);
        mods[0] = address(module);
        bool[] memory yes = new bool[](1);
        yes[0] = true;

        vm.startPrank(owner);
        dataProvider.configureModules(mods, yes);
        cashModule.configureModulesCanRequestWithdraw(mods, yes);
        roleRegistry.grantRole(roleRegistry.ADMIN_ROLE(), moduleAdmin);
        roleRegistry.grantRole(roleRegistry.ADMIN_TIMELOCK_ROLE(), moduleAdmin);
        address[] memory assets = new address[](2);
        assets[0] = address(wrapper);
        assets[1] = WSPYX;
        bool[] memory both = new bool[](2);
        both[0] = true;
        both[1] = true;
        cashModule.configureWithdrawAssets(assets, both);
        vm.stopPrank();

        bytes[] memory setupData = new bytes[](1);
        _configureModules(mods, yes, setupData);

        vm.prank(moduleAdmin);
        module.configureWrappers(_addr1(address(wrapper)), yes);

        raw.mint(address(this), AMOUNT);
        raw.approve(address(wrapper), AMOUNT);
        wrapper.deposit(AMOUNT, address(safe));

        vm.deal(keeper, KEEPER_ETH);
    }

    // ---- helpers ----

    function _addr1(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _order() internal view returns (StockBridgeWithdrawModule.Order memory) {
        return StockBridgeWithdrawModule.Order({ wrapper: address(wrapper), amount: AMOUNT, recipient: recipient, deadline: block.timestamp + 1 days });
    }

    function _signRequest(StockBridgeWithdrawModule.Order memory order) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(keccak256("StockBridgeWithdrawModule.requestWithdrawal"), block.chainid, address(module), safe.nonce(), address(safe), abi.encode(order))).toEthSignedMessageHash();
        return _twoSig(digest);
    }

    function _signCancel() internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(keccak256("StockBridgeWithdrawModule.cancelWithdrawal"), block.chainid, address(module), safe.nonce(), address(safe))).toEthSignedMessageHash();
        return _twoSig(digest);
    }

    function _twoSig(bytes32 digest) internal view returns (address[] memory, bytes[] memory) {
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        sigs[1] = abi.encodePacked(r2, s2, v2);
        return (signers, sigs);
    }

    function _request(StockBridgeWithdrawModule.Order memory order) internal {
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    function _expectRequestRevert(StockBridgeWithdrawModule.Order memory order, bytes4 selector) internal {
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        vm.expectRevert(selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    function _warpPastDelay() internal {
        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
    }

    function _pendingRecipient() internal view returns (address) {
        return cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient;
    }

    // ---- initialize ----

    function test_initialize_setsBridge() public view {
        (address b, uint64 selector) = module.getBridge();
        assertEq(b, address(bridge));
        assertEq(selector, ETH_SELECTOR);
        assertTrue(module.isWrapperSupported(address(wrapper)));
        assertEq(module.getSupportedWrappers().length, 1);
    }

    // ---- requestWithdrawal ----

    function test_requestWithdrawal_storesOrderAndPlacesHold() public {
        _request(_order());
        StockBridgeWithdrawModule.Order memory stored = module.getOrder(address(safe));
        assertEq(stored.wrapper, address(wrapper));
        assertEq(stored.amount, AMOUNT);
        assertEq(stored.recipient, recipient);
        assertEq(_pendingRecipient(), address(module));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.tokens[0], address(wrapper));
    }

    function test_requestWithdrawal_reverts_onBadOrders() public {
        StockBridgeWithdrawModule.Order memory order = _order();
        order.wrapper = address(raw);
        _expectRequestRevert(order, StockBridgeWithdrawModule.TokenNotSupported.selector);

        order = _order();
        order.amount = 0;
        _expectRequestRevert(order, ModuleBase.InvalidInput.selector);

        order = _order();
        order.recipient = address(0);
        _expectRequestRevert(order, ModuleBase.InvalidInput.selector);

        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        order = _order();
        order.deadline = block.timestamp + withdrawalDelay;
        _expectRequestRevert(order, StockBridgeWithdrawModule.DeadlineBeforeWithdrawalDelay.selector);
    }

    function test_requestWithdrawal_reverts_whenDelayZero() public {
        vm.prank(owner);
        cashModule.setDelays(0, 0, 0);
        _expectRequestRevert(_order(), StockBridgeWithdrawModule.ZeroWithdrawalDelay.selector);
    }

    function test_requestWithdrawal_reverts_whenOrderActive() public {
        _request(_order());
        _expectRequestRevert(_order(), StockBridgeWithdrawModule.OrderAlreadyActive.selector);
    }

    function test_requestWithdrawal_reverts_onBadSignature() public {
        StockBridgeWithdrawModule.Order memory tampered = _order();
        tampered.amount = AMOUNT - 1;
        (address[] memory signers, bytes[] memory sigs) = _signRequest(tampered);
        vm.expectRevert(StockBridgeWithdrawModule.InvalidSignatures.selector);
        module.requestWithdrawal(address(safe), _order(), signers, sigs);
    }

    // ---- executeWithdrawal ----

    function test_executeWithdrawal_redeemsAndBridgesRaw() public {
        _request(_order());
        _warpPastDelay();

        uint256 fee = bridge.fee();
        vm.expectEmit(true, false, false, false, address(module));
        emit StockBridgeWithdrawModule.BridgeWithdrawalExecuted(address(safe), bytes32(0), address(wrapper), AMOUNT, AMOUNT, recipient, bytes32(0));
        vm.prank(keeper);
        module.executeWithdrawal{ value: fee }(address(safe));

        assertEq(bridge.sends(), 1);
        assertEq(bridge.lastSelector(), ETH_SELECTOR);
        assertEq(bridge.lastReceiver(), bytes32(uint256(uint160(recipient))));
        assertEq(bridge.lastToken(), address(raw));
        assertEq(bridge.lastAmount(), AMOUNT);
        assertEq(raw.balanceOf(address(bridge)), AMOUNT, "raw not pulled by the bridge");
        assertEq(wrapper.balanceOf(address(safe)), 0);
        assertEq(wrapper.balanceOf(address(module)), 0);
        assertEq(raw.balanceOf(address(module)), 0);
        assertEq(raw.allowance(address(module), address(bridge)), 0);
        assertEq(keeper.balance, KEEPER_ETH - fee, "caller did not pay the fee");
        assertEq(address(module).balance, 0, "module kept native balance");
        assertEq(module.getOrder(address(safe)).wrapper, address(0));
        assertEq(_pendingRecipient(), address(0));
    }

    function test_executeWithdrawal_refundsExcessFee() public {
        _request(_order());
        _warpPastDelay();

        uint256 fee = bridge.fee();
        vm.prank(keeper);
        module.executeWithdrawal{ value: fee * 3 }(address(safe));
        assertEq(bridge.sends(), 1);
        assertEq(keeper.balance, KEEPER_ETH - fee, "excess not refunded");
        assertEq(address(module).balance, 0);
    }

    function test_executeWithdrawal_reverts_whenFeeShort() public {
        _request(_order());
        _warpPastDelay();

        uint256 fee = bridge.fee();
        vm.prank(keeper);
        vm.expectRevert(StockBridgeWithdrawModule.InsufficientNativeFee.selector);
        module.executeWithdrawal{ value: fee - 1 }(address(safe));
    }

    function test_executeWithdrawal_reverts_whenNoOrder() public {
        vm.expectRevert(StockBridgeWithdrawModule.NoActiveOrder.selector);
        module.executeWithdrawal(address(safe));
    }

    function test_executeWithdrawal_reverts_afterDeadline() public {
        StockBridgeWithdrawModule.Order memory order = _order();
        _request(order);
        vm.warp(order.deadline + 1);
        vm.expectRevert(StockBridgeWithdrawModule.OrderExpired.selector);
        module.executeWithdrawal(address(safe));
    }

    function test_executeWithdrawal_worksAtDeadline() public {
        StockBridgeWithdrawModule.Order memory order = _order();
        _request(order);
        vm.warp(order.deadline);
        uint256 fee = bridge.fee();
        vm.prank(keeper);
        module.executeWithdrawal{ value: fee }(address(safe));
        assertEq(bridge.sends(), 1);
    }

    function test_executeWithdrawal_reverts_beforeDelayMatures() public {
        _request(_order());
        vm.expectRevert();
        module.executeWithdrawal(address(safe));
    }

    function test_executeWithdrawal_reverts_whenWrapperRemoved() public {
        _request(_order());
        _warpPastDelay();

        bool[] memory no = new bool[](1);
        vm.prank(moduleAdmin);
        module.configureWrappers(_addr1(address(wrapper)), no);

        vm.expectRevert(StockBridgeWithdrawModule.TokenNotSupported.selector);
        module.executeWithdrawal(address(safe));

        // The hold is still releasable by the owners
        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        module.cancelWithdrawal(address(safe), signers, sigs);
        assertEq(_pendingRecipient(), address(0));
        assertEq(wrapper.balanceOf(address(safe)), AMOUNT);
    }

    function test_executeWithdrawal_reverts_whenPaused() public {
        _request(_order());
        _warpPastDelay();
        vm.prank(pauser);
        module.pause();
        vm.expectRevert();
        module.executeWithdrawal(address(safe));
    }

    // ---- fee view ----

    function test_getWithdrawalFee_quotesBridge() public {
        vm.expectRevert(StockBridgeWithdrawModule.NoActiveOrder.selector);
        module.getWithdrawalFee(address(safe));

        _request(_order());
        (address feeToken, uint256 fee) = module.getWithdrawalFee(address(safe));
        assertEq(feeToken, 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        assertEq(fee, bridge.fee());
    }

    // ---- cancels ----

    function test_cancelWithdrawal_clearsOrderAndHold() public {
        _request(_order());
        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        vm.expectEmit(true, false, false, false, address(module));
        emit StockBridgeWithdrawModule.BridgeWithdrawalCancelled(address(safe), bytes32(0));
        module.cancelWithdrawal(address(safe), signers, sigs);
        assertEq(module.getOrder(address(safe)).wrapper, address(0));
        assertEq(_pendingRecipient(), address(0));
    }

    function test_cancelWithdrawal_reverts_onBadSignature() public {
        _request(_order());
        (address[] memory signers, bytes[] memory sigs) = _twoSig(keccak256("wrong").toEthSignedMessageHash());
        vm.expectRevert(StockBridgeWithdrawModule.InvalidSignatures.selector);
        module.cancelWithdrawal(address(safe), signers, sigs);
    }

    function test_cancelExpiredWithdrawal_complementsExecute() public {
        StockBridgeWithdrawModule.Order memory order = _order();
        _request(order);

        vm.warp(order.deadline);
        vm.expectRevert(StockBridgeWithdrawModule.OrderNotExpired.selector);
        module.cancelExpiredWithdrawal(address(safe));

        vm.warp(order.deadline + 1);
        vm.prank(makeAddr("rando"));
        module.cancelExpiredWithdrawal(address(safe));
        assertEq(module.getOrder(address(safe)).wrapper, address(0));
        assertEq(_pendingRecipient(), address(0));
        assertEq(wrapper.balanceOf(address(safe)), AMOUNT, "wrapper never left the safe");
    }

    function test_cancelBridgeByCashModule_onlyCashModule() public {
        _request(_order());
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        module.cancelBridgeByCashModule(address(safe));

        vm.prank(address(cashModule));
        module.cancelBridgeByCashModule(address(safe));
        assertEq(module.getOrder(address(safe)).wrapper, address(0));
    }

    // ---- admin ----

    function test_configureWrappers_adminOnlyAndChecksBridge() public {
        bool[] memory yes = new bool[](1);
        yes[0] = true;
        ERC4626Mock other = new ERC4626Mock(address(new MockERC20("X", "X", 18)));

        vm.expectRevert(RoleRegistry.OnlyAdmin.selector);
        module.configureWrappers(_addr1(address(other)), yes);

        vm.prank(moduleAdmin);
        vm.expectRevert(StockBridgeWithdrawModule.TokenNotOnBridge.selector);
        module.configureWrappers(_addr1(address(other)), yes);

        bool[] memory no = new bool[](1);
        vm.prank(moduleAdmin);
        module.configureWrappers(_addr1(address(wrapper)), no);
        assertFalse(module.isWrapperSupported(address(wrapper)));
        assertEq(module.getSupportedWrappers().length, 0);
    }

    function test_setBridge_adminOnlyAndValidates() public {
        vm.expectRevert(RoleRegistry.OnlyAdminTimelock.selector);
        module.setBridge(address(bridge), 1);

        vm.startPrank(moduleAdmin);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.setBridge(address(0), 1);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.setBridge(address(bridge), 0);
        module.setBridge(address(bridge), 7);
        vm.stopPrank();

        (, uint64 selector) = module.getBridge();
        assertEq(selector, 7);
    }

    // ---- fork: the real wrapper and bridge on OP ----

    function test_fork_executeWithdrawal_overBackedBridge() public {
        vm.skip(block.chainid != 10);

        bool[] memory yes = new bool[](1);
        yes[0] = true;
        vm.prank(moduleAdmin);
        module.setBridge(BACKED_BRIDGE, ETH_SELECTOR);
        vm.prank(moduleAdmin);
        module.configureWrappers(_addr1(WSPYX), yes);

        // A bridge payout is a plain transfer from custody; wrap one for the safe
        vm.startPrank(BACKED_CUSTODY);
        IERC20(SPYX).approve(WSPYX, 1e18);
        uint256 shares = IERC4626(WSPYX).deposit(1e18, address(safe));
        vm.stopPrank();

        StockBridgeWithdrawModule.Order memory order = StockBridgeWithdrawModule.Order({ wrapper: WSPYX, amount: shares, recipient: recipient, deadline: block.timestamp + 1 days });
        _request(order);
        _warpPastDelay();

        (, uint256 fee) = module.getWithdrawalFee(address(safe));
        uint256 custodyBefore = IERC20(SPYX).balanceOf(BACKED_CUSTODY);
        uint256 expectedRaw = IERC4626(WSPYX).previewRedeem(shares);

        vm.prank(keeper);
        module.executeWithdrawal{ value: fee }(address(safe));

        assertGe(IERC20(SPYX).balanceOf(BACKED_CUSTODY) - custodyBefore, expectedRaw - 2, "custody did not receive the stock");
        assertLe(IERC20(SPYX).balanceOf(address(module)), 2, "raw stock left behind");
        assertEq(IERC20(WSPYX).balanceOf(address(safe)), 0);
        assertEq(keeper.balance, KEEPER_ETH - fee, "caller did not pay the fee");
        assertEq(_pendingRecipient(), address(0));
    }
}
