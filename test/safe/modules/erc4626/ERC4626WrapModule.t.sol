// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { ModuleCheckBalance } from "../../../../src/modules/ModuleCheckBalance.sol";
import { ERC4626WrapModule } from "../../../../src/modules/erc4626/ERC4626WrapModule.sol";
import { MessageHashUtils, SafeTestSetup } from "../../SafeTestSetup.t.sol";

/**
 * @notice A vault whose `asset()` can be repointed after the fact, to exercise the
 *         module's decision to pin the asset at registration.
 */
contract MutableAssetVault {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    function setAsset(address _asset) external {
        asset = _asset;
    }
}

/**
 * @notice A synchronous-looking ERC-4626 that queues instead of minting, standing in for
 *         an async vault an admin might register by mistake.
 */
contract QueueingVault is ERC20 {
    address public immutable asset;

    constructor(address _asset) ERC20("Queueing Vault", "qV") {
        asset = _asset;
    }

    function deposit(uint256 assets, address) external returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        return 0; // queued for a later epoch; no shares minted now
    }
}

/**
 * @title ERC4626WrapModuleTest
 * @notice Tests `ERC4626WrapModule` against the real Frankencoin savings vault on OP:
 *         svZCHF (`SavingsVault ZCHF`) wrapping ZCHF.
 * @dev svZCHF is yield-bearing, so shares and assets are deliberately NOT 1:1 — every
 *      expected amount here comes from `previewDeposit` / `previewRedeem` rather than
 *      assuming parity.
 */
contract ERC4626WrapModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    ERC4626WrapModule wrapModule;

    IERC20 constant zchf = IERC20(0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553);
    IERC4626 constant svZchf = IERC4626(0x20191448fcC813d34D0BDeae5Cdb1E89B3Fb7b8E);
    uint256 constant OP_CHAIN_ID = 10;

    uint256 constant AMOUNT = 100 ether; // ZCHF is 18 decimals

    function setUp() public override {
        super.setUp();
        vm.skip(block.chainid != OP_CHAIN_ID, "svZCHF savings vault only exists on OP");

        vm.startPrank(owner);

        address[] memory vaults = new address[](1);
        vaults[0] = address(svZchf);
        wrapModule = new ERC4626WrapModule(address(dataProvider), vaults);

        address[] memory modules = new address[](1);
        modules[0] = address(wrapModule);
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        dataProvider.configureDefaultModules(modules, flags);
        cashModule.configureModulesCanRequestWithdraw(modules, flags);

        address[] memory assets = new address[](2);
        assets[0] = address(zchf);
        assets[1] = address(svZchf);
        bool[] memory assetFlags = new bool[](2);
        assetFlags[0] = true;
        assetFlags[1] = true;
        cashModule.configureWithdrawAssets(assets, assetFlags);

        roleRegistry.grantRole(wrapModule.ERC4626_MODULE_ADMIN(), owner);

        vm.stopPrank();
    }

    /// @dev Signs a `wrap` as safe admin `owner1`. Kept separate from submission so that a
    ///      `vm.expectRevert` in a test binds to `wrap` itself and not to one of the view
    ///      calls this helper makes — otherwise the negative tests pass vacuously.
    function _signWrap(address vault, uint256 assets, uint256 minShares) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(wrapModule.WRAP_SIG(), block.chainid, address(wrapModule), wrapModule.getNonce(address(safe)), address(safe), abi.encode(vault, assets, minShares))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Signs an `unwrap` as safe admin `owner1`. Split for the same reason as `_signWrap`.
    function _signUnwrap(address vault, uint256 shares, uint256 minAssets) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(wrapModule.UNWRAP_SIG(), block.chainid, address(wrapModule), wrapModule.getNonce(address(safe)), address(safe), abi.encode(vault, shares, minAssets))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _wrap(address vault, uint256 assets, uint256 minShares) internal {
        wrapModule.wrap(address(safe), vault, assets, minShares, owner1, _signWrap(vault, assets, minShares));
    }

    function _unwrap(address vault, uint256 shares, uint256 minAssets) internal {
        wrapModule.unwrap(address(safe), vault, shares, minAssets, owner1, _signUnwrap(vault, shares, minAssets));
    }

    function test_wrap_depositsZchfAndCreditsShares() public {
        deal(address(zchf), address(safe), AMOUNT);
        uint256 expectedShares = svZchf.previewDeposit(AMOUNT);
        // The premise of the whole suite: this vault accrues, so parity would be a false expectation.
        assertTrue(expectedShares != AMOUNT, "svZCHF should not be 1:1 with ZCHF");

        _wrap(address(svZchf), AMOUNT, expectedShares);

        assertEq(zchf.balanceOf(address(safe)), 0, "all ZCHF should have been deposited");
        assertEq(IERC20(address(svZchf)).balanceOf(address(safe)), expectedShares, "safe should hold the minted shares");
    }

    function test_unwrap_redeemsSharesBackToZchf() public {
        deal(address(zchf), address(safe), AMOUNT);
        _wrap(address(svZchf), AMOUNT, svZchf.previewDeposit(AMOUNT));

        uint256 shares = IERC20(address(svZchf)).balanceOf(address(safe));
        uint256 expectedAssets = svZchf.previewRedeem(shares);

        _unwrap(address(svZchf), shares, expectedAssets);

        assertEq(IERC20(address(svZchf)).balanceOf(address(safe)), 0, "all shares should have been redeemed");
        assertEq(zchf.balanceOf(address(safe)), expectedAssets, "safe should hold the redeemed ZCHF");
    }

    /// @dev `execTransactionFromModule` makes the safe itself the caller, so on
    ///      `redeem(shares, safe, safe)` the owner IS msg.sender and ERC-4626 requires no
    ///      allowance. Pins that the unwrap leg never grants one.
    function test_unwrap_grantsNoAllowanceToTheVault() public {
        deal(address(zchf), address(safe), AMOUNT);
        _wrap(address(svZchf), AMOUNT, svZchf.previewDeposit(AMOUNT));

        uint256 shares = IERC20(address(svZchf)).balanceOf(address(safe));
        _unwrap(address(svZchf), shares, svZchf.previewRedeem(shares));

        assertEq(IERC20(address(svZchf)).allowance(address(safe), address(svZchf)), 0, "unwrap must not approve the vault");
    }

    function test_wrap_revertsWhenSharesBelowMinShares() public {
        deal(address(zchf), address(safe), AMOUNT);

        uint256 tooManyShares = svZchf.previewDeposit(AMOUNT) + 1;
        bytes memory signature = _signWrap(address(svZchf), AMOUNT, tooManyShares);

        vm.expectRevert(ERC4626WrapModule.InsufficientReturnAmount.selector);
        wrapModule.wrap(address(safe), address(svZchf), AMOUNT, tooManyShares, owner1, signature);
    }

    function test_unwrap_revertsWhenAssetsBelowMinAssets() public {
        deal(address(zchf), address(safe), AMOUNT);
        _wrap(address(svZchf), AMOUNT, svZchf.previewDeposit(AMOUNT));

        uint256 shares = IERC20(address(svZchf)).balanceOf(address(safe));

        uint256 tooManyAssets = svZchf.previewRedeem(shares) + 1;
        bytes memory signature = _signUnwrap(address(svZchf), shares, tooManyAssets);

        vm.expectRevert(ERC4626WrapModule.InsufficientReturnAmount.selector);
        wrapModule.unwrap(address(safe), address(svZchf), shares, tooManyAssets, owner1, signature);
    }

    function test_wrap_revertsForUnsupportedVault() public {
        deal(address(zchf), address(safe), AMOUNT);

        bytes memory signature = _signWrap(address(usdc), AMOUNT, 0);

        vm.expectRevert(ERC4626WrapModule.UnsupportedVault.selector);
        wrapModule.wrap(address(safe), address(usdc), AMOUNT, 0, owner1, signature);
    }

    function test_wrap_revertsWhenSafeDoesNotHoldTheAssets() public {
        bytes memory signature = _signWrap(address(svZchf), AMOUNT, 0);

        vm.expectRevert(ModuleCheckBalance.InsufficientAvailableBalanceOnSafe.selector);
        wrapModule.wrap(address(safe), address(svZchf), AMOUNT, 0, owner1, signature);
    }

    function test_wrap_revertsWhenSignerIsNotASafeAdmin() public {
        deal(address(zchf), address(safe), AMOUNT);

        bytes32 digest = keccak256(abi.encodePacked(wrapModule.WRAP_SIG(), block.chainid, address(wrapModule), wrapModule.getNonce(address(safe)), address(safe), abi.encode(address(svZchf), AMOUNT, uint256(0)))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(uint256(keccak256("stranger")), digest);

        vm.expectRevert(ModuleBase.OnlySafeAdmin.selector);
        wrapModule.wrap(address(safe), address(svZchf), AMOUNT, 0, notOwner, abi.encodePacked(r, s, v));
    }

    function test_wrap_revertsWhenSignatureDoesNotMatchTheDigest() public {
        deal(address(zchf), address(safe), AMOUNT);

        // Signed for a different amount than the one submitted.
        bytes32 digest = keccak256(abi.encodePacked(wrapModule.WRAP_SIG(), block.chainid, address(wrapModule), wrapModule.getNonce(address(safe)), address(safe), abi.encode(address(svZchf), AMOUNT / 2, uint256(0)))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);

        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        wrapModule.wrap(address(safe), address(svZchf), AMOUNT, 0, owner1, abi.encodePacked(r, s, v));
    }

    function test_wrap_revertsWhenSignatureIsReplayed() public {
        deal(address(zchf), address(safe), 2 * AMOUNT);

        uint256 nonce = wrapModule.getNonce(address(safe));
        bytes32 digest = keccak256(abi.encodePacked(wrapModule.WRAP_SIG(), block.chainid, address(wrapModule), nonce, address(safe), abi.encode(address(svZchf), AMOUNT, uint256(0)))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        wrapModule.wrap(address(safe), address(svZchf), AMOUNT, 0, owner1, signature);

        // The nonce moved on, so the same signature no longer matches the new digest.
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        wrapModule.wrap(address(safe), address(svZchf), AMOUNT, 0, owner1, signature);
    }

    /// @dev The module stores `asset()` when the admin registers the vault, so a vault that
    ///      later repoints its asset cannot redirect a safe's funds into a token nobody
    ///      approved. A live `asset()` read at call time would follow the repoint.
    function test_addVaults_pinsTheAssetAtRegistration() public {
        MutableAssetVault shifty = new MutableAssetVault(address(zchf));

        address[] memory vaults = new address[](1);
        vaults[0] = address(shifty);
        vm.prank(owner);
        wrapModule.addVaults(vaults);

        assertEq(wrapModule.vaultAsset(address(shifty)), address(zchf), "asset should be pinned at registration");

        shifty.setAsset(address(usdc));

        assertEq(wrapModule.vaultAsset(address(shifty)), address(zchf), "repointing the vault must not change the registered asset");
    }

    /// @dev An async vault that queues instead of minting yields zero shares, so the
    ///      `minShares` floor rejects it rather than silently swallowing the deposit.
    function test_wrap_revertsForAQueueingVaultThatMintsNothing() public {
        QueueingVault queueing = new QueueingVault(address(zchf));

        address[] memory vaults = new address[](1);
        vaults[0] = address(queueing);
        vm.prank(owner);
        wrapModule.addVaults(vaults);

        deal(address(zchf), address(safe), AMOUNT);

        bytes memory signature = _signWrap(address(queueing), AMOUNT, 1);

        vm.expectRevert(ERC4626WrapModule.InsufficientReturnAmount.selector);
        wrapModule.wrap(address(safe), address(queueing), AMOUNT, 1, owner1, signature);
    }

    function test_addVaults_revertsForNonAdmin() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(svZchf);

        vm.prank(notOwner);
        vm.expectRevert(ERC4626WrapModule.Unauthorized.selector);
        wrapModule.addVaults(vaults);
    }

    function test_removeVaults_makesTheVaultUnusable() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(svZchf);
        vm.prank(owner);
        wrapModule.removeVaults(vaults);

        assertEq(wrapModule.vaultAsset(address(svZchf)), address(0), "vault should be deregistered");

        deal(address(zchf), address(safe), AMOUNT);
        bytes memory signature = _signWrap(address(svZchf), AMOUNT, 0);

        vm.expectRevert(ERC4626WrapModule.UnsupportedVault.selector);
        wrapModule.wrap(address(safe), address(svZchf), AMOUNT, 0, owner1, signature);
    }

    function test_removeVaults_revertsForNonAdmin() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(svZchf);

        vm.prank(notOwner);
        vm.expectRevert(ERC4626WrapModule.Unauthorized.selector);
        wrapModule.removeVaults(vaults);
    }
}
