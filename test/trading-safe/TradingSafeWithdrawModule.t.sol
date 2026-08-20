// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ITradingSafeWithdrawModule, Withdrawal } from "../../src/interfaces/ITradingSafeWithdrawModule.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiSafeErrors } from "../../src/safe/EtherFiSafeErrors.sol";
import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { TradingSafeWithdrawModule } from "../../src/trading-safe/TradingSafeWithdrawModule.sol";
import { TradingSafeTestBase } from "./TradingSafeTestBase.t.sol";

/// @dev ERC20 that returns `false` from transfer without moving funds — exercises the strict
///      balance-delta assertion in `withdraw`.
contract FalseTransferToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Stand-in for the `WrappedBackedToken` ERC-4626 vaults the mainnet TradingSafe holds every
///      tokenized equity in (wTSLAx over TSLAx, etc.): shares are 1:1 with the underlying's shares,
///      and a multiplier — which the real underlying moves on stock splits, dividends and fee
///      accrual — converts them to an asset amount.
contract MockWrappedToken is ERC20 {
    MockERC20 public immutable underlying;
    uint256 public multiplier = 1e18;

    constructor(MockERC20 _underlying) ERC20("Wrapped Mock", "wMOCK") {
        underlying = _underlying;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function setMultiplier(uint256 newMultiplier) external {
        multiplier = newMultiplier;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return (shares * multiplier) / 1e18;
    }

    /// @dev Wraps by escrowing the underlying, so the vault can always cover a redeem.
    function mintShares(address to, uint256 shares) external {
        underlying.mint(address(this), convertToAssets(shares));
        _mint(to, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        assets = convertToAssets(shares);
        _burn(owner, shares);
        underlying.transfer(receiver, assets);
    }
}

/// @dev ERC-4626-shaped vault whose `redeem` moves nothing, to prove the balance-delta check still
///      guards the unwrap path the same way it guards a plain transfer.
contract NoOpRedeemVault {
    address public immutable asset;

    mapping(address => uint256) public balanceOf;

    constructor(address _asset) {
        asset = _asset;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function redeem(uint256, address, address) external pure returns (uint256) {
        return 0;
    }
}

contract TradingSafeWithdrawModuleTest is TradingSafeTestBase {
    using MessageHashUtils for bytes32;

    TradingSafeFactory internal factory;
    TradingSafeWithdrawModule internal module;
    TradingSafe internal safe;
    MockERC20 internal token;
    MockERC20 internal underlying;
    MockWrappedToken internal wrapper;

    address internal safeAddr;
    address internal recipient = makeAddr("recipient");
    address internal relayer = makeAddr("relayer");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");

    address internal owner1;
    uint256 internal owner1Pk;
    address internal owner2;
    uint256 internal owner2Pk;

    /// @dev Never-expiring deadline for the tests that don't exercise expiry.
    uint256 internal constant DEADLINE = type(uint256).max;

    function setUp() public {
        (owner1, owner1Pk) = makeAddrAndKey("owner1");
        (owner2, owner2Pk) = makeAddrAndKey("owner2");

        _setupCore();

        vm.startPrank(owner);
        factory = _deployFactory();
        _initDataProvider(address(factory));

        roleRegistry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), owner);
        roleRegistry.grantRole(dataProvider.ADMIN_ROLE(), owner);
        roleRegistry.grantRole(dataProvider.ADMIN_TIMELOCK_ROLE(), owner);
        roleRegistry.grantRole(roleRegistry.PAUSER(), pauser);
        roleRegistry.grantRole(roleRegistry.UNPAUSER(), unpauser);

        module = new TradingSafeWithdrawModule(address(dataProvider));

        // Register as a DEFAULT module so it is enabled on every TradingSafe automatically.
        address[] memory mods = new address[](1);
        mods[0] = address(module);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        dataProvider.configureDefaultModules(mods, flags);

        address[] memory initialOwners = new address[](2);
        initialOwners[0] = owner1;
        initialOwners[1] = owner2;
        safe = _deployTradingSafe(factory, makeAddr("sourceSafe"), initialOwners, 2);
        safeAddr = address(safe);

        token = new MockERC20("Trade", "TRD", 18);
        underlying = new MockERC20("Mock xStock", "MOCKx", 18);
        wrapper = new MockWrappedToken(underlying);
        vm.stopPrank();
    }

    // ---- Happy path ----

    function test_withdraw_transfersExactAmountAndEmits() public {
        uint256 held = 1000e18;
        uint256 amount = 400e18;
        token.mint(safeAddr, held);

        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, amount, DEADLINE);

        vm.expectEmit(true, true, true, true, address(module));
        emit ITradingSafeWithdrawModule.Withdrawn(safeAddr, address(token), recipient, amount);

        // Permissionless relay: an arbitrary caller submits the owner-signed authorization.
        vm.prank(relayer);
        _withdraw(address(token), recipient, amount, DEADLINE, signers, sigs);

        assertEq(token.balanceOf(recipient), amount, "recipient credited exact amount");
        assertEq(token.balanceOf(safeAddr), held - amount, "safe keeps the remainder");
    }

    function test_withdraw_toArbitraryRecipient() public {
        address arbitrary = makeAddr("arbitraryDestination");
        uint256 amount = 250e18;
        token.mint(safeAddr, amount);

        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), arbitrary, amount, DEADLINE);

        _withdraw(address(token), arbitrary, amount, DEADLINE, signers, sigs);
        assertEq(token.balanceOf(arbitrary), amount, "arbitrary recipient credited");
    }

    // ---- Batch (multiple tokens) ----

    function test_withdraw_multipleTokensInOneBatch() public {
        MockERC20 token2 = new MockERC20("Trade2", "TRD2", 6);
        uint256 amount1 = 400e18;
        uint256 amount2 = 150e6;
        token.mint(safeAddr, 1000e18);
        token2.mint(safeAddr, 500e6);

        Withdrawal[] memory legs = new Withdrawal[](2);
        legs[0] = Withdrawal(address(token), amount1, false);
        legs[1] = Withdrawal(address(token2), amount2, false);

        (address[] memory signers, bytes[] memory sigs) = _signWithdrawMulti(legs, recipient, DEADLINE);

        vm.expectEmit(true, true, true, true, address(module));
        emit ITradingSafeWithdrawModule.Withdrawn(safeAddr, address(token), recipient, amount1);
        vm.expectEmit(true, true, true, true, address(module));
        emit ITradingSafeWithdrawModule.Withdrawn(safeAddr, address(token2), recipient, amount2);

        vm.prank(relayer);
        module.withdraw(safeAddr, legs, recipient, DEADLINE, signers, sigs);

        assertEq(token.balanceOf(recipient), amount1, "token1 credited");
        assertEq(token2.balanceOf(recipient), amount2, "token2 credited");
        assertEq(token.balanceOf(safeAddr), 1000e18 - amount1, "token1 remainder kept");
        assertEq(token2.balanceOf(safeAddr), 500e6 - amount2, "token2 remainder kept");
    }

    /// @dev One over-drawn token in the batch reverts the whole withdrawal (all-or-nothing).
    function test_withdraw_batchRevertsIfOneTokenInsufficient() public {
        MockERC20 token2 = new MockERC20("Trade2", "TRD2", 18);
        token.mint(safeAddr, 1000e18);
        token2.mint(safeAddr, 100e18);

        Withdrawal[] memory legs = new Withdrawal[](2);
        legs[0] = Withdrawal(address(token), 400e18, false);
        legs[1] = Withdrawal(address(token2), 101e18, false);

        (address[] memory signers, bytes[] memory sigs) = _signWithdrawMulti(legs, recipient, DEADLINE);

        vm.expectRevert(ITradingSafeWithdrawModule.InsufficientBalance.selector);
        module.withdraw(safeAddr, legs, recipient, DEADLINE, signers, sigs);
        assertEq(token.balanceOf(recipient), 0, "no partial transfer");
    }

    function test_withdraw_revertsOnEmptyWithdrawals() public {
        address[] memory signers = new address[](0);
        bytes[] memory sigs = new bytes[](0);

        vm.expectRevert(ITradingSafeWithdrawModule.EmptyWithdrawal.selector);
        module.withdraw(safeAddr, new Withdrawal[](0), recipient, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsOnDuplicateToken() public {
        token.mint(safeAddr, 1000e18);
        Withdrawal[] memory legs = new Withdrawal[](2);
        legs[0] = Withdrawal(address(token), 1e18, false);
        legs[1] = Withdrawal(address(token), 2e18, false);

        (address[] memory signers, bytes[] memory sigs) = _signWithdrawMulti(legs, recipient, DEADLINE);

        vm.expectRevert(ITradingSafeWithdrawModule.DuplicateToken.selector);
        module.withdraw(safeAddr, legs, recipient, DEADLINE, signers, sigs);
    }

    // ---- Unwrap (ERC-4626 redeem) ----

    function test_withdraw_unwrapDeliversUnderlyingNotWrapper() public {
        uint256 held = 100e18;
        uint256 shares = 40e18;
        wrapper.mintShares(safeAddr, held);

        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(wrapper), recipient, shares, true, DEADLINE);

        vm.expectEmit(true, true, true, true, address(module));
        emit ITradingSafeWithdrawModule.Withdrawn(safeAddr, address(wrapper), recipient, shares);
        vm.expectEmit(true, true, true, true, address(module));
        emit ITradingSafeWithdrawModule.Unwrapped(safeAddr, address(wrapper), recipient, address(underlying), shares);

        vm.prank(relayer);
        _withdraw(address(wrapper), recipient, shares, true, DEADLINE, signers, sigs);

        assertEq(underlying.balanceOf(recipient), shares, "recipient got the underlying");
        assertEq(wrapper.balanceOf(recipient), 0, "recipient got no wrapper");
        assertEq(wrapper.balanceOf(safeAddr), held - shares, "safe debited exactly the signed shares");
    }

    /// @dev `amounts` is always denominated in what the safe holds, so a multiplier away from 1:1
    ///      (a stock split or accrued fee on the real Backed token) changes what the recipient
    ///      receives without changing what the owners authorized debiting.
    function test_withdraw_unwrapConvertsAtCurrentMultiplier() public {
        uint256 shares = 10e18;
        wrapper.mintShares(safeAddr, shares);
        wrapper.setMultiplier(1.5e18);
        // Back the revalued shares, as a split/dividend on the real Backed token would.
        underlying.mint(address(wrapper), 5e18);

        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(wrapper), recipient, shares, true, DEADLINE);
        _withdraw(address(wrapper), recipient, shares, true, DEADLINE, signers, sigs);

        assertEq(underlying.balanceOf(recipient), 15e18, "recipient credited shares * multiplier");
        assertEq(wrapper.balanceOf(safeAddr), 0, "safe debited exactly the signed shares");
    }

    function test_withdraw_deliversWrapperWhenUnwrapNotRequested() public {
        uint256 shares = 10e18;
        wrapper.mintShares(safeAddr, shares);

        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(wrapper), recipient, shares, DEADLINE);
        _withdraw(address(wrapper), recipient, shares, DEADLINE, signers, sigs);

        assertEq(wrapper.balanceOf(recipient), shares, "recipient got the wrapper");
        assertEq(underlying.balanceOf(recipient), 0, "no unwrap happened");
    }

    function test_withdraw_mixesUnwrappedAndPlainTokensInOneBatch() public {
        token.mint(safeAddr, 1000e18);
        wrapper.mintShares(safeAddr, 100e18);

        Withdrawal[] memory legs = new Withdrawal[](2);
        legs[0] = Withdrawal(address(token), 400e18, false);
        legs[1] = Withdrawal(address(wrapper), 30e18, true);

        (address[] memory signers, bytes[] memory sigs) = _signWithdrawMulti(legs, recipient, DEADLINE);

        vm.prank(relayer);
        module.withdraw(safeAddr, legs, recipient, DEADLINE, signers, sigs);

        assertEq(token.balanceOf(recipient), 400e18, "plain token transferred as-is");
        assertEq(underlying.balanceOf(recipient), 30e18, "vault entry delivered as underlying");
        assertEq(wrapper.balanceOf(recipient), 0, "no wrapper delivered");
        assertEq(wrapper.balanceOf(safeAddr), 70e18, "safe debited exactly the signed shares");
    }

    function test_withdraw_revertsIfUnwrapRequestedForPlainToken() public {
        token.mint(safeAddr, 10e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, true, DEADLINE);

        vm.expectRevert(ITradingSafeWithdrawModule.NotUnwrappable.selector);
        _withdraw(address(token), recipient, 1e18, true, DEADLINE, signers, sigs);
    }

    /// @dev The unwrap flag is part of the signed digest, so a relayer cannot decide on the owners'
    ///      behalf whether the recipient ends up with the wrapper or the underlying.
    function test_withdraw_revertsIfSignatureOverDifferentUnwrapFlag() public {
        wrapper.mintShares(safeAddr, 10e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(wrapper), recipient, 1e18, false, DEADLINE);

        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        _withdraw(address(wrapper), recipient, 1e18, true, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsIfUnwrapMovesNothing() public {
        NoOpRedeemVault vault = new NoOpRedeemVault(address(underlying));
        vault.mint(safeAddr, 5e18);

        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(vault), recipient, 5e18, true, DEADLINE);

        vm.expectRevert(ITradingSafeWithdrawModule.WithdrawTransferFailed.selector);
        _withdraw(address(vault), recipient, 5e18, true, DEADLINE, signers, sigs);
    }

    // ---- Input validation ----

    function test_withdraw_revertsIfTokenZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(0), recipient, 1e18, DEADLINE);
        vm.expectRevert(ITradingSafeWithdrawModule.InvalidToken.selector);
        _withdraw(address(0), recipient, 1e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsIfRecipientZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), address(0), 1e18, DEADLINE);
        vm.expectRevert(ITradingSafeWithdrawModule.InvalidRecipient.selector);
        _withdraw(address(token), address(0), 1e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsIfAmountZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 0, DEADLINE);
        vm.expectRevert(ITradingSafeWithdrawModule.InvalidAmount.selector);
        _withdraw(address(token), recipient, 0, DEADLINE, signers, sigs);
    }

    /// @dev A stashed signature must not be replayable against a future deposit once expired.
    function test_withdraw_revertsIfExpired() public {
        token.mint(safeAddr, 1e18);
        uint256 deadline = block.timestamp + 1 hours;
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(ITradingSafeWithdrawModule.WithdrawExpired.selector);
        _withdraw(address(token), recipient, 1e18, deadline, signers, sigs);
    }

    function test_withdraw_revertsIfInsufficientBalance() public {
        token.mint(safeAddr, 100e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 101e18, DEADLINE);
        vm.expectRevert(ITradingSafeWithdrawModule.InsufficientBalance.selector);
        _withdraw(address(token), recipient, 101e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsForNonTradingSafe() public {
        address notASafe = makeAddr("notASafe");
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, DEADLINE);
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        module.withdraw(notASafe, _single(address(token), 1e18, false), recipient, DEADLINE, signers, sigs);
    }

    // ---- Signature / replay ----

    function test_withdraw_revertsIfSignatureOverDifferentAmount() public {
        token.mint(safeAddr, 10e18);
        // Sign over 1e18, submit 2e18 -> digest mismatch.
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, DEADLINE);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        _withdraw(address(token), recipient, 2e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsIfSignatureOverDifferentRecipient() public {
        token.mint(safeAddr, 10e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, DEADLINE);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        _withdraw(address(token), makeAddr("other"), 1e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsOnNonceReplay() public {
        token.mint(safeAddr, 4e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 2e18, DEADLINE);

        _withdraw(address(token), recipient, 2e18, DEADLINE, signers, sigs);
        // Safe nonce advanced; the same signatures no longer match.
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        _withdraw(address(token), recipient, 2e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsIfBelowThreshold() public {
        token.mint(safeAddr, 4e18);
        (, bytes[] memory fullSigs) = _signWithdraw(address(token), recipient, 2e18, DEADLINE);

        address[] memory oneSigner = new address[](1);
        oneSigner[0] = owner1;
        bytes[] memory oneSig = new bytes[](1);
        oneSig[0] = fullSigs[0];

        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        _withdraw(address(token), recipient, 2e18, DEADLINE, oneSigner, oneSig);
    }

    // ---- Module enablement ----

    function test_withdraw_revertsIfModuleNotEnabledOnSafe() public {
        // A second module whitelisted on the data provider but neither default nor enabled on the safe.
        TradingSafeWithdrawModule module2 = new TradingSafeWithdrawModule(address(dataProvider));
        address[] memory mods = new address[](1);
        mods[0] = address(module2);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        vm.prank(owner);
        dataProvider.configureModules(mods, flags);

        token.mint(safeAddr, 1e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdrawFor(address(module2), address(token), recipient, 1e18, DEADLINE);
        // The safe rejects the unenabled module when it tries to consume the nonce.
        vm.expectRevert(EtherFiSafeErrors.OnlyModules.selector);
        module2.withdraw(safeAddr, _single(address(token), 1e18, false), recipient, DEADLINE, signers, sigs);
    }

    // ---- Pause ----

    function test_withdraw_revertsWhenPaused() public {
        vm.prank(pauser);
        module.pause();

        token.mint(safeAddr, 1e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, DEADLINE);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        _withdraw(address(token), recipient, 1e18, DEADLINE, signers, sigs);
    }

    function test_pause_onlyPauser() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(RoleRegistry.OnlyPauser.selector);
        module.pause();
    }

    function test_unpause_onlyUnpauser() public {
        vm.prank(pauser);
        module.pause();

        vm.prank(makeAddr("random"));
        vm.expectRevert(RoleRegistry.OnlyUnpauser.selector);
        module.unpause();

        vm.prank(unpauser);
        module.unpause();

        // Withdrawals work again after unpausing.
        token.mint(safeAddr, 1e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, DEADLINE);
        _withdraw(address(token), recipient, 1e18, DEADLINE, signers, sigs);
        assertEq(token.balanceOf(recipient), 1e18, "withdrawal resumes after unpause");
    }

    // ---- Token behavior ----

    function test_withdraw_revertsOnFalseReturningToken() public {
        FalseTransferToken bad = new FalseTransferToken();
        bad.mint(safeAddr, 5e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(bad), recipient, 5e18, DEADLINE);
        vm.expectRevert(ITradingSafeWithdrawModule.WithdrawTransferFailed.selector);
        _withdraw(address(bad), recipient, 5e18, DEADLINE, signers, sigs);
    }

    // --- helpers ---

    /// @dev Convenience single-token withdraw against the default `module`, delivering the token as held.
    function _withdraw(address token_, address recipient_, uint256 amount_, uint256 deadline_, address[] memory signers, bytes[] memory sigs) internal {
        _withdraw(token_, recipient_, amount_, false, deadline_, signers, sigs);
    }

    function _withdraw(address token_, address recipient_, uint256 amount_, bool unwrap_, uint256 deadline_, address[] memory signers, bytes[] memory sigs) internal {
        module.withdraw(safeAddr, _single(token_, amount_, unwrap_), recipient_, deadline_, signers, sigs);
    }

    function _signWithdraw(address token_, address recipient_, uint256 amount_, uint256 deadline_) internal view returns (address[] memory signers, bytes[] memory sigs) {
        return _signWithdraw(token_, recipient_, amount_, false, deadline_);
    }

    function _signWithdraw(address token_, address recipient_, uint256 amount_, bool unwrap_, uint256 deadline_) internal view returns (address[] memory signers, bytes[] memory sigs) {
        return _signWithdrawMultiFor(address(module), _single(token_, amount_, unwrap_), recipient_, deadline_);
    }

    function _signWithdrawFor(address module_, address token_, address recipient_, uint256 amount_, uint256 deadline_) internal view returns (address[] memory signers, bytes[] memory sigs) {
        return _signWithdrawMultiFor(module_, _single(token_, amount_, false), recipient_, deadline_);
    }

    function _signWithdrawMulti(Withdrawal[] memory legs, address recipient_, uint256 deadline_) internal view returns (address[] memory signers, bytes[] memory sigs) {
        return _signWithdrawMultiFor(address(module), legs, recipient_, deadline_);
    }

    function _signWithdrawMultiFor(address module_, Withdrawal[] memory legs, address recipient_, uint256 deadline_) internal view returns (address[] memory signers, bytes[] memory sigs) {
        bytes32 digest = keccak256(abi.encodePacked(keccak256("TradingSafeWithdrawModule.withdraw"), block.chainid, module_, safe.nonce(), safeAddr, keccak256(abi.encode(legs)), recipient_, deadline_)).toEthSignedMessageHash();

        signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        sigs = new bytes[](2);
        sigs[0] = _signDigest(owner1Pk, digest);
        sigs[1] = _signDigest(owner2Pk, digest);
    }

    function _single(address token_, uint256 amount_, bool unwrap_) internal pure returns (Withdrawal[] memory legs) {
        legs = new Withdrawal[](1);
        legs[0] = Withdrawal(token_, amount_, unwrap_);
    }

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
