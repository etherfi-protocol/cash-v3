// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { StockWithdrawModule } from "../../src/stock-withdraw/StockWithdrawModule.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { UpgradeableProxy } from "../../src/utils/UpgradeableProxy.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { SendParam, MessagingFee, MessagingReceipt, OFTLimit, OFTFeeDetail, OFTReceipt } from "../../src/interfaces/IOFT.sol";
import { SafeTestSetup } from "../safe/SafeTestSetup.t.sol";

/// @dev ShadowOFT stand-in: an ERC20 that is its own OFT (token() == address(this),
///      approvalRequired() == false), recording the last send() for assertions.
contract OFTStub is ERC20 {
    uint256 public callCount;
    uint32 public lastDstEid;
    bytes32 public lastTo;
    uint256 public lastAmountLD;
    uint256 public lastMinAmountLD;
    bytes public lastExtraOptions;
    bytes public lastComposeMsg;
    uint256 public nativeFee = 0.01 ether;
    uint256 public dust; // simulated shared-decimal rounding loss

    constructor() ERC20("iWrapped SPY Stock", "iwSPYx") { }

    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function setNativeFee(uint256 f) external { nativeFee = f; }
    function setDust(uint256 d) external { dust = d; }

    function token() external view returns (address) { return address(this); }
    function approvalRequired() external pure returns (bool) { return false; }

    function quoteOFT(SendParam calldata p) external view returns (OFTLimit memory limit, OFTFeeDetail[] memory details, OFTReceipt memory receipt) {
        limit = OFTLimit(0, type(uint256).max);
        receipt = OFTReceipt(p.amountLD, p.amountLD - dust);
        return (limit, details, receipt);
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee(nativeFee, 0);
    }

    function send(SendParam calldata p, MessagingFee calldata fee, address) external payable returns (MessagingReceipt memory mr, OFTReceipt memory oftReceipt) {
        require(msg.value == fee.nativeFee, "OFTStub: bad fee");
        _burn(msg.sender, p.amountLD);
        callCount++;
        lastDstEid = p.dstEid;
        lastTo = p.to;
        lastAmountLD = p.amountLD;
        lastMinAmountLD = p.minAmountLD;
        lastExtraOptions = p.extraOptions;
        lastComposeMsg = p.composeMsg;
        return (mr, OFTReceipt(p.amountLD, p.amountLD - dust));
    }
}

contract StockWithdrawModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    StockWithdrawModule internal module;
    OFTStub internal oft;

    address internal keeper = makeAddr("keeper");
    address internal moduleAdmin = makeAddr("moduleAdmin");
    address internal stockRecipient = makeAddr("stockRecipient");
    address internal unwrapper = makeAddr("stockUnwrapper");
    address internal feeReceiver = makeAddr("feeReceiver");

    uint32 internal constant DST_EID = 30101; // Ethereum mainnet EID
    uint128 internal constant COMPOSE_GAS = 300_000;
    uint256 internal constant AMOUNT = 100e18;
    uint256 internal constant MIN_RETURN = 99e18;

    function setUp() public override {
        super.setUp();

        oft = new OFTStub();

        // Full config passed atomically at initialize: compose gas, supported tokens and
        // the dstEid -> unwrapper route.
        address[] memory iTokens = new address[](1);
        iTokens[0] = address(oft);
        bool[] memory supported = new bool[](1);
        supported[0] = true;
        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = DST_EID;
        address[] memory unwrappers = new address[](1);
        unwrappers[0] = unwrapper;

        address impl = address(new StockWithdrawModule(address(dataProvider)));
        module = StockWithdrawModule(payable(address(new UUPSProxy(
            impl,
            abi.encodeCall(StockWithdrawModule.initialize, (StockWithdrawModule.InitParams({
                roleRegistry: address(roleRegistry),
                composeGasLimit: COMPOSE_GAS,
                providerFeeBps: 0,
                feeReceiver: feeReceiver,
                iTokens: iTokens,
                supported: supported,
                dstEids: dstEids,
                unwrappers: unwrappers
            })))
        ))));

        address[] memory mods = new address[](1);
        mods[0] = address(module);
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        vm.startPrank(owner);
        dataProvider.configureModules(mods, shouldWhitelist);
        cashModule.configureModulesCanRequestWithdraw(mods, shouldWhitelist);
        roleRegistry.grantRole(module.STOCK_WITHDRAW_MODULE_ADMIN_ROLE(), moduleAdmin);

        // Whitelist the iToken as a withdrawable asset in CashModule
        address[] memory withdrawAssets = new address[](1);
        withdrawAssets[0] = address(oft);
        cashModule.configureWithdrawAssets(withdrawAssets, shouldWhitelist);
        vm.stopPrank();

        bytes[] memory setupData = new bytes[](1);
        _configureModules(mods, shouldWhitelist, setupData);

        oft.mint(address(safe), AMOUNT);
        vm.deal(keeper, 1 ether);
    }

    // ---- helpers ----

    function _baseOrder() internal view returns (StockWithdrawModule.Order memory) {
        return StockWithdrawModule.Order({
            iToken: address(oft),
            amount: AMOUNT,
            minReturn: MIN_RETURN,
            deadline: block.timestamp + 1 days,
            recipient: stockRecipient,
            dstEid: DST_EID
        });
    }

    function _signRequest(StockWithdrawModule.Order memory order) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(
            keccak256("StockWithdrawModule.requestWithdrawal"),
            block.chainid,
            address(module),
            safe.nonce(),
            address(safe),
            abi.encode(order)
        )).toEthSignedMessageHash();
        return _twoSig(digest);
    }

    function _signCancel() internal view returns (address[] memory, bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(
            keccak256("StockWithdrawModule.cancelWithdrawal"),
            block.chainid,
            address(module),
            safe.nonce(),
            address(safe)
        )).toEthSignedMessageHash();
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

    function _request(StockWithdrawModule.Order memory order) internal {
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    function _warpPastDelay() internal {
        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
    }

    function _setUnwrapper(uint32 dstEid, address newUnwrapper) internal {
        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = dstEid;
        address[] memory unwrappers = new address[](1);
        unwrappers[0] = newUnwrapper;
        vm.prank(moduleAdmin);
        module.configureUnwrappers(dstEids, unwrappers);
    }

    // ---- initialize ----

    function test_initialize_setsFullConfig() public view {
        assertEq(module.getComposeGasLimit(), COMPOSE_GAS);
        (uint16 feeBps, address receiver) = module.getProviderFee();
        assertEq(feeBps, 0);
        assertEq(receiver, feeReceiver);
        assertTrue(module.isTokenSupported(address(oft)));
        assertEq(module.getSupportedTokens().length, 1);
        assertEq(module.getSupportedTokens()[0], address(oft));
        assertEq(module.getStockUnwrapper(DST_EID), unwrapper);

        (uint32[] memory dstEids, address[] memory unwrappers) = module.getConfiguredUnwrappers();
        assertEq(dstEids.length, 1);
        assertEq(dstEids[0], DST_EID);
        assertEq(unwrappers[0], unwrapper);
    }

    // ---- requestWithdrawal ----

    function test_requestWithdrawal_storesOrderAndPlacesHold() public {
        _request(_baseOrder());
        assertEq(module.getOrder(address(safe)).amount, AMOUNT);
        assertEq(module.getOrder(address(safe)).iToken, address(oft));
        assertEq(module.getOrder(address(safe)).dstEid, DST_EID);
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(module));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.tokens[0], address(oft));
    }

    function test_requestWithdrawal_revertsForUnsupportedToken() public {
        StockWithdrawModule.Order memory order = _baseOrder();
        order.iToken = makeAddr("rogueToken");
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        vm.expectRevert(StockWithdrawModule.TokenNotSupported.selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    function test_requestWithdrawal_revertsForZeroInputs() public {
        StockWithdrawModule.Order memory order = _baseOrder();
        order.amount = 0;
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);

        order = _baseOrder();
        order.recipient = address(0);
        (signers, sigs) = _signRequest(order);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);

        order = _baseOrder();
        order.minReturn = 0;
        (signers, sigs) = _signRequest(order);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    function test_requestWithdrawal_revertsForUnconfiguredDstEid() public {
        StockWithdrawModule.Order memory order = _baseOrder();
        order.dstEid = DST_EID + 1;
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        vm.expectRevert(StockWithdrawModule.MissingConfig.selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    function test_requestWithdrawal_revertsWhenDeadlineDoesNotOutlastWithdrawalDelay() public {
        StockWithdrawModule.Order memory order = _baseOrder();
        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        order.deadline = block.timestamp + withdrawalDelay;
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        vm.expectRevert(StockWithdrawModule.DeadlineBeforeWithdrawalDelay.selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    function test_requestWithdrawal_revertsWhenWithdrawalDelayIsZero() public {
        vm.prank(owner);
        cashModule.setDelays(0, 0, 0);
        StockWithdrawModule.Order memory order = _baseOrder();
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        vm.expectRevert(StockWithdrawModule.ZeroWithdrawalDelay.selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    function test_requestWithdrawal_revertsWhenOrderAlreadyActive() public {
        _request(_baseOrder());
        StockWithdrawModule.Order memory order = _baseOrder();
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        vm.expectRevert(StockWithdrawModule.OrderAlreadyActive.selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    function test_requestWithdrawal_revertsForBadSignature() public {
        StockWithdrawModule.Order memory order = _baseOrder();
        StockWithdrawModule.Order memory tampered = _baseOrder();
        tampered.minReturn = MIN_RETURN + 1;
        (address[] memory signers, bytes[] memory sigs) = _signRequest(tampered);
        vm.expectRevert(StockWithdrawModule.InvalidSignatures.selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    function test_requestWithdrawal_revertsWhenUnwrapperRemoved() public {
        _setUnwrapper(DST_EID, address(0));

        StockWithdrawModule.Order memory order = _baseOrder();
        (address[] memory signers, bytes[] memory sigs) = _signRequest(order);
        vm.expectRevert(StockWithdrawModule.MissingConfig.selector);
        module.requestWithdrawal(address(safe), order, signers, sigs);
    }

    // ---- executeWithdrawal ----

    function test_executeWithdrawal_sendsOftWithComposeMsg() public {
        StockWithdrawModule.Order memory order = _baseOrder();
        _request(order);
        _warpPastDelay();

        vm.prank(keeper);
        module.executeWithdrawal{ value: 0.01 ether }(address(safe));

        assertEq(oft.callCount(), 1);
        assertEq(oft.lastDstEid(), DST_EID);
        assertEq(oft.lastTo(), bytes32(uint256(uint160(unwrapper))));
        assertEq(oft.lastAmountLD(), AMOUNT);
        assertEq(oft.lastComposeMsg(), abi.encode(address(safe), stockRecipient, MIN_RETURN, order.deadline));
        // TYPE_3 ‖ workerId=1 ‖ optionLength=19 ‖ OPTION_TYPE_LZCOMPOSE=3 ‖ index=0 ‖ gas —
        // the manual equivalent of OptionsBuilder.addExecutorLzComposeOption(0, gas, 0).
        assertEq(oft.lastExtraOptions(), abi.encodePacked(uint16(3), uint8(1), uint16(19), uint8(3), uint16(0), COMPOSE_GAS));
        // iTOKEN was pulled from the safe into the module and burned by the OFT send
        assertEq(oft.balanceOf(address(safe)), 0);
        assertEq(oft.balanceOf(address(module)), 0);
        // order + hold cleared
        assertEq(module.getOrder(address(safe)).iToken, address(0));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    function test_executeWithdrawal_usesLiveUnwrapperFromStorage() public {
        _request(_baseOrder());

        // Admin repoints the route after the user signed: execute must honor storage.
        address newUnwrapper = makeAddr("newUnwrapper");
        _setUnwrapper(DST_EID, newUnwrapper);
        _warpPastDelay();

        vm.prank(keeper);
        module.executeWithdrawal{ value: 0.01 ether }(address(safe));

        assertEq(oft.lastTo(), bytes32(uint256(uint160(newUnwrapper))), "unwrapper resolved live");
    }

    function test_executeWithdrawal_revertsWhenRouteDisabled() public {
        _request(_baseOrder());
        _setUnwrapper(DST_EID, address(0));
        _warpPastDelay();

        vm.prank(keeper);
        vm.expectRevert(StockWithdrawModule.MissingConfig.selector);
        module.executeWithdrawal{ value: 0.01 ether }(address(safe));
    }

    function test_executeWithdrawal_adjustsMinAmountForOftDust() public {
        oft.setDust(1e12);
        _request(_baseOrder());
        _warpPastDelay();
        vm.prank(keeper);
        module.executeWithdrawal{ value: 0.01 ether }(address(safe));
        assertEq(oft.lastMinAmountLD(), AMOUNT - 1e12, "minAmountLD set from quoteOFT");
    }

    function test_executeWithdrawal_refundsExcessFeeToCaller() public {
        _request(_baseOrder());
        _warpPastDelay();
        uint256 balBefore = keeper.balance;
        vm.prank(keeper);
        module.executeWithdrawal{ value: 0.5 ether }(address(safe));
        assertEq(balBefore - keeper.balance, 0.01 ether, "only the LZ fee is spent");
    }

    function test_executeWithdrawal_revertsForInsufficientFee() public {
        _request(_baseOrder());
        _warpPastDelay();
        vm.prank(keeper);
        vm.expectRevert(StockWithdrawModule.InsufficientNativeFee.selector);
        module.executeWithdrawal{ value: 0.001 ether }(address(safe));
    }

    function test_executeWithdrawal_permissionless() public {
        _request(_baseOrder());
        _warpPastDelay();
        address rando = makeAddr("rando");
        vm.deal(rando, 1 ether);
        vm.prank(rando);
        module.executeWithdrawal{ value: 0.01 ether }(address(safe));
        assertEq(oft.callCount(), 1);
    }

    function test_executeWithdrawal_revertsForNoActiveOrder() public {
        vm.prank(keeper);
        vm.expectRevert(StockWithdrawModule.NoActiveOrder.selector);
        module.executeWithdrawal(address(safe));
    }

    function test_executeWithdrawal_revertsAfterDeadline() public {
        StockWithdrawModule.Order memory order = _baseOrder();
        _request(order);
        vm.warp(order.deadline + 1);
        vm.prank(keeper);
        vm.expectRevert(StockWithdrawModule.OrderExpired.selector);
        module.executeWithdrawal(address(safe));
    }

    function test_executeWithdrawal_revertsBeforeDelayMatures() public {
        _request(_baseOrder());
        vm.prank(keeper);
        vm.expectRevert(); // CashModule.processWithdrawal enforces finalizeTime
        module.executeWithdrawal{ value: 0.01 ether }(address(safe));
    }

    // ---- fee view ----

    function test_getWithdrawalFee_returnsEthAndQuote() public {
        _request(_baseOrder());
        (address feeToken, uint256 fee) = module.getWithdrawalFee(address(safe));
        assertEq(feeToken, 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        assertEq(fee, 0.01 ether);
    }

    // ---- cancels ----

    function test_cancelWithdrawal_clearsOrderAndHold() public {
        _request(_baseOrder());
        (address[] memory signers, bytes[] memory sigs) = _signCancel();
        vm.expectEmit(true, false, false, false, address(module));
        emit StockWithdrawModule.WithdrawalCancelled(address(safe), bytes32(0));
        module.cancelWithdrawal(address(safe), signers, sigs);
        assertEq(module.getOrder(address(safe)).iToken, address(0));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    function test_cancelWithdrawal_revertsForBadSig() public {
        _request(_baseOrder());
        (address[] memory signers, bytes[] memory sigs) = _twoSig(keccak256("wrong").toEthSignedMessageHash());
        vm.expectRevert(StockWithdrawModule.InvalidSignatures.selector);
        module.cancelWithdrawal(address(safe), signers, sigs);
    }

    function test_cancelExpiredWithdrawal_permissionlessAfterDeadline() public {
        StockWithdrawModule.Order memory order = _baseOrder();
        _request(order);
        vm.warp(order.deadline + 1);
        vm.prank(makeAddr("rando"));
        module.cancelExpiredWithdrawal(address(safe));
        assertEq(module.getOrder(address(safe)).iToken, address(0));
        assertEq(cashModule.getData(address(safe)).pendingWithdrawalRequest.recipient, address(0));
    }

    function test_cancelExpiredWithdrawal_revertsBeforeDeadline() public {
        StockWithdrawModule.Order memory order = _baseOrder();
        _request(order);
        vm.warp(order.deadline); // inclusive boundary: not yet expired
        vm.expectRevert(StockWithdrawModule.OrderNotExpired.selector);
        module.cancelExpiredWithdrawal(address(safe));
    }

    function test_cancelBridgeByCashModule_onlyCashModule() public {
        _request(_baseOrder());
        vm.expectRevert(UpgradeableProxy.Unauthorized.selector);
        module.cancelBridgeByCashModule(address(safe));

        vm.prank(address(cashModule));
        module.cancelBridgeByCashModule(address(safe));
        assertEq(module.getOrder(address(safe)).iToken, address(0));
    }

    // ---- admin config ----

    function test_configureTokens_adminOnlyAndValidatesOft() public {
        address[] memory iTokens = new address[](1);
        iTokens[0] = address(oft);
        bool[] memory supported = new bool[](1);
        supported[0] = true;

        vm.expectRevert(StockWithdrawModule.OnlyAdmin.selector);
        module.configureTokens(iTokens, supported);

        // a token whose OFT.token() != itself must be rejected
        OFTStub other = new OFTStub();
        vm.mockCall(address(other), abi.encodeWithSignature("token()"), abi.encode(makeAddr("someOtherToken")));
        iTokens[0] = address(other);
        vm.prank(moduleAdmin);
        vm.expectRevert(StockWithdrawModule.InvalidOFT.selector);
        module.configureTokens(iTokens, supported);
    }

    function test_configureTokens_removesFromEnumerableSet() public {
        address[] memory iTokens = new address[](1);
        iTokens[0] = address(oft);
        bool[] memory supported = new bool[](1);
        supported[0] = false;

        vm.prank(moduleAdmin);
        module.configureTokens(iTokens, supported);

        assertFalse(module.isTokenSupported(address(oft)));
        assertEq(module.getSupportedTokens().length, 0);
    }

    function test_configureUnwrappers_adminOnlyStoresAndRemoves() public {
        uint32[] memory dstEids = new uint32[](1);
        dstEids[0] = 30102;
        address[] memory unwrappers = new address[](1);
        unwrappers[0] = makeAddr("otherUnwrapper");

        vm.expectRevert(StockWithdrawModule.OnlyAdmin.selector);
        module.configureUnwrappers(dstEids, unwrappers);

        vm.prank(moduleAdmin);
        module.configureUnwrappers(dstEids, unwrappers);
        assertEq(module.getStockUnwrapper(30102), makeAddr("otherUnwrapper"));

        (uint32[] memory eids,) = module.getConfiguredUnwrappers();
        assertEq(eids.length, 2, "both routes enumerable");

        // zero removes the route from the enumerable map
        _setUnwrapper(30102, address(0));
        assertEq(module.getStockUnwrapper(30102), address(0));
        (eids,) = module.getConfiguredUnwrappers();
        assertEq(eids.length, 1, "removed route not enumerated");
    }

    function test_setComposeGasLimit_adminOnlyAndStores() public {
        vm.expectRevert(StockWithdrawModule.OnlyAdmin.selector);
        module.setComposeGasLimit(500_000);

        vm.prank(moduleAdmin);
        module.setComposeGasLimit(500_000);
        assertEq(module.getComposeGasLimit(), 500_000);
    }

    // ---- provider fee ----

    function test_setProviderFee_adminOnlyCapAndValidation() public {
        vm.expectRevert(StockWithdrawModule.OnlyAdmin.selector);
        module.setProviderFee(100, feeReceiver);

        vm.startPrank(moduleAdmin);
        // above the 1000 bps cap
        vm.expectRevert(StockWithdrawModule.ProviderFeeTooHigh.selector);
        module.setProviderFee(1001, feeReceiver);

        // non-zero fee requires a real receiver
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        module.setProviderFee(100, address(0));

        // max fee is allowed
        module.setProviderFee(1000, feeReceiver);
        (uint16 feeBps, address receiver) = module.getProviderFee();
        assertEq(feeBps, 1000);
        assertEq(receiver, feeReceiver);

        // zero disables the fee (zero receiver allowed then)
        module.setProviderFee(0, address(0));
        (feeBps, receiver) = module.getProviderFee();
        assertEq(feeBps, 0);
        assertEq(receiver, address(0));
        vm.stopPrank();
    }

    function test_executeWithdrawal_takesProviderFeeAndBridgesNet() public {
        vm.prank(moduleAdmin);
        module.setProviderFee(100, feeReceiver); // 1%

        StockWithdrawModule.Order memory order = _baseOrder();
        _request(order);
        _warpPastDelay();

        uint256 expectedFee = AMOUNT / 100;
        vm.expectEmit(true, false, false, true, address(module));
        emit StockWithdrawModule.WithdrawalExecuted(address(safe), bytes32(0), address(oft), AMOUNT, expectedFee, stockRecipient);

        vm.prank(keeper);
        module.executeWithdrawal{ value: 0.01 ether }(address(safe));

        assertEq(oft.balanceOf(feeReceiver), expectedFee, "fee receiver got the wrapped-stock fee");
        assertEq(oft.lastAmountLD(), AMOUNT - expectedFee, "net amount bridged");
        assertEq(oft.balanceOf(address(module)), 0, "nothing left in the module");
        // the order terms in the compose message are untouched by the fee
        assertEq(oft.lastComposeMsg(), abi.encode(address(safe), stockRecipient, MIN_RETURN, order.deadline));
    }

    function test_executeWithdrawal_zeroFee_takesNothing() public {
        _request(_baseOrder());
        _warpPastDelay();
        vm.prank(keeper);
        module.executeWithdrawal{ value: 0.01 ether }(address(safe));
        assertEq(oft.balanceOf(feeReceiver), 0, "no fee taken when disabled");
        assertEq(oft.lastAmountLD(), AMOUNT, "full amount bridged");
    }
}
