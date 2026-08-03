// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ITradingSafeWithdrawModule } from "../../src/interfaces/ITradingSafeWithdrawModule.sol";
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

contract TradingSafeWithdrawModuleTest is TradingSafeTestBase {
    using MessageHashUtils for bytes32;

    TradingSafeFactory internal factory;
    TradingSafeWithdrawModule internal module;
    TradingSafe internal safe;
    MockERC20 internal token;

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
        roleRegistry.grantRole(dataProvider.DATA_PROVIDER_ADMIN_ROLE(), owner);
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
        module.withdraw(safeAddr, address(token), recipient, amount, DEADLINE, signers, sigs);

        assertEq(token.balanceOf(recipient), amount, "recipient credited exact amount");
        assertEq(token.balanceOf(safeAddr), held - amount, "safe keeps the remainder");
    }

    function test_withdraw_toArbitraryRecipient() public {
        address arbitrary = makeAddr("arbitraryDestination");
        uint256 amount = 250e18;
        token.mint(safeAddr, amount);

        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), arbitrary, amount, DEADLINE);

        module.withdraw(safeAddr, address(token), arbitrary, amount, DEADLINE, signers, sigs);
        assertEq(token.balanceOf(arbitrary), amount, "arbitrary recipient credited");
    }

    // ---- Input validation ----

    function test_withdraw_revertsIfTokenZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(0), recipient, 1e18, DEADLINE);
        vm.expectRevert(ITradingSafeWithdrawModule.InvalidToken.selector);
        module.withdraw(safeAddr, address(0), recipient, 1e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsIfRecipientZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), address(0), 1e18, DEADLINE);
        vm.expectRevert(ITradingSafeWithdrawModule.InvalidRecipient.selector);
        module.withdraw(safeAddr, address(token), address(0), 1e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsIfAmountZero() public {
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 0, DEADLINE);
        vm.expectRevert(ITradingSafeWithdrawModule.InvalidAmount.selector);
        module.withdraw(safeAddr, address(token), recipient, 0, DEADLINE, signers, sigs);
    }

    /// @dev A stashed signature must not be replayable against a future deposit once expired.
    function test_withdraw_revertsIfExpired() public {
        token.mint(safeAddr, 1e18);
        uint256 deadline = block.timestamp + 1 hours;
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, deadline);

        vm.warp(deadline + 1);
        vm.expectRevert(ITradingSafeWithdrawModule.WithdrawExpired.selector);
        module.withdraw(safeAddr, address(token), recipient, 1e18, deadline, signers, sigs);
    }

    function test_withdraw_revertsIfInsufficientBalance() public {
        token.mint(safeAddr, 100e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 101e18, DEADLINE);
        vm.expectRevert(ITradingSafeWithdrawModule.InsufficientBalance.selector);
        module.withdraw(safeAddr, address(token), recipient, 101e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsForNonTradingSafe() public {
        address notASafe = makeAddr("notASafe");
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, DEADLINE);
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        module.withdraw(notASafe, address(token), recipient, 1e18, DEADLINE, signers, sigs);
    }

    // ---- Signature / replay ----

    function test_withdraw_revertsIfSignatureOverDifferentAmount() public {
        token.mint(safeAddr, 10e18);
        // Sign over 1e18, submit 2e18 -> digest mismatch.
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, DEADLINE);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.withdraw(safeAddr, address(token), recipient, 2e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsIfSignatureOverDifferentRecipient() public {
        token.mint(safeAddr, 10e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, DEADLINE);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.withdraw(safeAddr, address(token), makeAddr("other"), 1e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsOnNonceReplay() public {
        token.mint(safeAddr, 4e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 2e18, DEADLINE);

        module.withdraw(safeAddr, address(token), recipient, 2e18, DEADLINE, signers, sigs);
        // Safe nonce advanced; the same signatures no longer match.
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.withdraw(safeAddr, address(token), recipient, 2e18, DEADLINE, signers, sigs);
    }

    function test_withdraw_revertsIfBelowThreshold() public {
        token.mint(safeAddr, 4e18);
        (, bytes[] memory fullSigs) = _signWithdraw(address(token), recipient, 2e18, DEADLINE);

        address[] memory oneSigner = new address[](1);
        oneSigner[0] = owner1;
        bytes[] memory oneSig = new bytes[](1);
        oneSig[0] = fullSigs[0];

        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        module.withdraw(safeAddr, address(token), recipient, 2e18, DEADLINE, oneSigner, oneSig);
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
        module2.withdraw(safeAddr, address(token), recipient, 1e18, DEADLINE, signers, sigs);
    }

    // ---- Pause ----

    function test_withdraw_revertsWhenPaused() public {
        vm.prank(pauser);
        module.pause();

        token.mint(safeAddr, 1e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(token), recipient, 1e18, DEADLINE);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        module.withdraw(safeAddr, address(token), recipient, 1e18, DEADLINE, signers, sigs);
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
        module.withdraw(safeAddr, address(token), recipient, 1e18, DEADLINE, signers, sigs);
        assertEq(token.balanceOf(recipient), 1e18, "withdrawal resumes after unpause");
    }

    // ---- Token behavior ----

    function test_withdraw_revertsOnFalseReturningToken() public {
        FalseTransferToken bad = new FalseTransferToken();
        bad.mint(safeAddr, 5e18);
        (address[] memory signers, bytes[] memory sigs) = _signWithdraw(address(bad), recipient, 5e18, DEADLINE);
        vm.expectRevert(ITradingSafeWithdrawModule.WithdrawTransferFailed.selector);
        module.withdraw(safeAddr, address(bad), recipient, 5e18, DEADLINE, signers, sigs);
    }

    // --- helpers ---

    function _signWithdraw(address token_, address recipient_, uint256 amount_, uint256 deadline_) internal view returns (address[] memory signers, bytes[] memory sigs) {
        return _signWithdrawFor(address(module), token_, recipient_, amount_, deadline_);
    }

    function _signWithdrawFor(address module_, address token_, address recipient_, uint256 amount_, uint256 deadline_) internal view returns (address[] memory signers, bytes[] memory sigs) {
        bytes32 digest = keccak256(abi.encodePacked(keccak256("TradingSafeWithdrawModule.withdraw"), block.chainid, module_, safe.nonce(), safeAddr, token_, recipient_, amount_, deadline_)).toEthSignedMessageHash();

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
