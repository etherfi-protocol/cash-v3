// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { CCIPAdapter } from "../../src/top-up/bridge/CCIPAdapter.sol";
import { Constants } from "../../src/utils/Constants.sol";

/// @dev A vault whose `asset()` disagrees with what the admin claims, to exercise the
///      registry's pairing check.
contract MismatchedVault {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }
}

/**
 * @title TopUpFactoryUnwrapTest
 * @notice Tests the unwrap-in-place flow on an OP fork against the real Frankencoin savings
 *         vault: a TopUp holding svZCHF redeems it into ZCHF inside itself, so the ordinary
 *         sweep → bridge path carries it out over the CCIP lane that only ZCHF has.
 * @dev Mirrors the wrap-on-redirect shape: the vault pairing is configuration read off the
 *      factory rather than a parameter, and the entry point is permissionless for the same
 *      reason the sweeps are — anyone may pay the gas to move a user's asset along its
 *      intended path, and the proceeds can land nowhere but the TopUp that held the shares.
 *
 *      svZCHF is yield-bearing, so expectations come from `previewRedeem`, and shares must be
 *      MINTED by depositing — `deal` would move a balance without moving `totalSupply`, letting
 *      a redemption claim assets this small vault does not hold.
 */
contract TopUpFactoryUnwrapTest is Test, Constants {
    TopUpFactory factory;
    RoleRegistry roleRegistry;
    CCIPAdapter ccipAdapter;
    TopUp topUp;

    address owner = makeAddr("owner");
    address recipientOnDest = makeAddr("recipientOnDest");
    address dataProvider = makeAddr("dataProvider");
    address anyone = makeAddr("anyone");

    IERC20 constant zchf = IERC20(0xD4dD9e2F021BB459D5A5f6c24C12fE09c5D45553);
    IERC4626 constant svZchf = IERC4626(0x20191448fcC813d34D0BDeae5Cdb1E89B3Fb7b8E);
    IERC20 constant weth = IERC20(0x4200000000000000000000000000000000000006);

    /// @dev CCIP Router on OP Mainnet, and the selector for the mainnet lane that carries ZCHF.
    address constant CCIP_ROUTER = 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f;
    uint64 constant MAINNET_CHAIN_SELECTOR = 5009297550715157269;
    uint256 constant MAINNET_CHAIN_ID = 1;

    uint256 constant DEPOSIT = 100 ether;

    function setUp() public {
        string memory rpcUrl = vm.envString("OPTIMISM_RPC");
        if (bytes(rpcUrl).length == 0) rpcUrl = "https://optimism.gateway.tenderly.co";
        vm.createSelectFork(rpcUrl, 155820000);

        vm.startPrank(owner);
        ccipAdapter = new CCIPAdapter();

        address roleRegistryImpl = address(new RoleRegistry(dataProvider));
        roleRegistry = RoleRegistry(address(new UUPSProxy(roleRegistryImpl, abi.encodeWithSelector(RoleRegistry.initialize.selector, owner))));

        TopUp topUpImpl = new TopUp(address(weth));
        address factoryImpl = address(new TopUpFactory());
        factory = TopUpFactory(payable(address(new UUPSProxy(factoryImpl, abi.encodeWithSelector(TopUpFactory.initialize.selector, address(roleRegistry), address(topUpImpl))))));

        // ZCHF is the bridgeable asset; svZCHF deliberately gets no bridge config, which is
        // what makes it eligible to be unwrapped.
        _configureBridge(address(zchf));
        _registerUnwrapVault(address(svZchf), address(zchf));

        bytes32 salt = keccak256("unwrap-user");
        factory.deployTopUpContract(salt);
        topUp = TopUp(payable(factory.getDeterministicAddress(salt)));

        roleRegistry.grantRole(factory.TOPUP_FACTORY_BRIDGER_ROLE(), address(this));
        vm.stopPrank();
    }

    function _configureBridge(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = MAINNET_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: address(ccipAdapter), recipientOnDestChain: recipientOnDest, maxSlippageInBps: 0, additionalData: abi.encode(CCIP_ROUTER, MAINNET_CHAIN_SELECTOR) });
        factory.setTokenConfig(tokens, chainIds, configs);
    }

    function _registerUnwrapVault(address vault, address asset) internal {
        address[] memory vaults = new address[](1);
        vaults[0] = vault;
        address[] memory assets = new address[](1);
        assets[0] = asset;
        factory.setUnwrapVaults(vaults, assets);
    }

    /// @dev Mints real svZCHF by depositing ZCHF as a third party, then hands the shares to the
    ///      TopUp — so the vault actually holds the ZCHF backing the redemption under test.
    function _fundTopUpWithShares(uint256 assetsIn) internal returns (uint256 shares) {
        address depositor = makeAddr("depositor");
        deal(address(zchf), depositor, assetsIn);

        vm.startPrank(depositor);
        zchf.approve(address(svZchf), assetsIn);
        shares = svZchf.deposit(assetsIn, depositor);
        IERC20(address(svZchf)).transfer(address(topUp), shares);
        vm.stopPrank();
    }

    function _sweep(address token) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        address[] memory contracts = new address[](1);
        contracts[0] = address(topUp);
        factory.processTopUpFromContracts(tokens, contracts);
    }

    function test_setUnwrapVaults_recordsTheVerifiedPairing() public view {
        assertEq(factory.unwrapAssetFor(address(svZchf)), address(zchf), "svZCHF should be registered against ZCHF");
    }

    /// @dev Establishes why unwrapping in place is needed at all: the sweep only accepts tokens
    ///      this factory bridges, so svZCHF can never leave a TopUp as itself.
    function test_sweep_cannotMoveTheWrappedForm() public {
        _fundTopUpWithShares(DEPOSIT);

        vm.expectRevert(TopUpFactory.OnlySupportedTokens.selector);
        _sweep(address(svZchf));
    }

    /// @dev The shares are redeemed into the TopUp itself, not swept to the factory: that is what
    ///      lets the ordinary sweep path pick the proceeds up as an ordinary topup asset.
    function test_unwrap_redeemsIntoTheTopUpItself() public {
        uint256 shares = _fundTopUpWithShares(DEPOSIT);
        uint256 expectedAssets = svZchf.previewRedeem(shares);
        assertTrue(expectedAssets != shares, "svZCHF should not be 1:1 with ZCHF");

        vm.recordLogs();
        factory.unwrap(address(topUp), address(svZchf), shares);
        _assertUnwrapLog(vm.getRecordedLogs(), address(topUp), address(svZchf), address(zchf), shares, expectedAssets);

        assertEq(IERC20(address(svZchf)).balanceOf(address(topUp)), 0, "all shares should have been redeemed");
        assertEq(zchf.balanceOf(address(topUp)), expectedAssets, "the TopUp should hold the redeemed ZCHF");
        assertEq(zchf.balanceOf(address(factory)), 0, "the factory must not receive the proceeds directly");
        assertEq(IERC20(address(svZchf)).allowance(address(topUp), address(svZchf)), 0, "redeem must not need an allowance");
    }

    /// @dev "Callable by everyone": no role, no owner, no allowlist on the caller.
    function test_unwrap_isPermissionless() public {
        uint256 shares = _fundTopUpWithShares(DEPOSIT);

        assertFalse(roleRegistry.hasRole(factory.TOPUP_FACTORY_BRIDGER_ROLE(), anyone), "premise: caller holds no role");
        vm.prank(anyone);
        factory.unwrap(address(topUp), address(svZchf), shares);

        assertGt(zchf.balanceOf(address(topUp)), 0, "an unprivileged caller should be able to unwrap");
    }

    /// @dev The whole point: after unwrapping in place the proceeds move through the ordinary
    ///      topup pipeline with no special casing — sweep to the factory, then bridge.
    function test_unwrap_thenSweepAndBridge() public {
        uint256 shares = _fundTopUpWithShares(DEPOSIT);

        vm.prank(anyone);
        factory.unwrap(address(topUp), address(svZchf), shares);

        _sweep(address(zchf));

        uint256 assets = zchf.balanceOf(address(factory));
        assertGt(assets, 0, "sweep should have moved the unwrapped ZCHF to the factory");
        assertEq(zchf.balanceOf(address(topUp)), 0, "the TopUp should have been drained by the sweep");

        (, uint256 fee) = factory.getBridgeFee(address(zchf), assets, MAINNET_CHAIN_ID);
        factory.bridge{ value: fee }(address(zchf), assets, MAINNET_CHAIN_ID);

        assertEq(zchf.balanceOf(address(factory)), 0, "unwrapped ZCHF should have been bridged");
    }

    function test_unwrap_revertsForAnUnregisteredVault() public {
        vm.expectRevert(TopUpFactory.VaultNotUnwrappable.selector);
        factory.unwrap(address(topUp), address(weth), 1 ether);
    }

    /// @dev The constraint that defines this feature: a vault that is itself a configured topup
    ///      asset must be bridged, never unwrapped.
    function test_unwrap_revertsWhenTheVaultIsItselfATopupAsset() public {
        vm.prank(owner);
        _configureBridge(address(svZchf));

        uint256 shares = _fundTopUpWithShares(DEPOSIT);

        vm.expectRevert(TopUpFactory.OnlyUnsupportedTokens.selector);
        factory.unwrap(address(topUp), address(svZchf), shares);
    }

    function test_unwrap_revertsForAnAddressThatIsNotOneOfOurTopUps() public {
        vm.expectRevert(TopUpFactory.InvalidTopUpAddress.selector);
        factory.unwrap(makeAddr("notATopUp"), address(svZchf), DEPOSIT);
    }

    function test_unwrap_revertsOnZeroAmount() public {
        vm.expectRevert(TopUp.InvalidAmount.selector);
        factory.unwrap(address(topUp), address(svZchf), 0);
    }

    function test_unwrap_revertsWhenTheTopUpHoldsTooFewShares() public {
        uint256 shares = _fundTopUpWithShares(DEPOSIT);

        vm.expectRevert();
        factory.unwrap(address(topUp), address(svZchf), shares + 1);
    }

    /// @dev Only the factory owner may drive the TopUp's redemption; the permissionless entry
    ///      point is the factory's, which applies the registry and topup-asset guards first.
    function test_topUpUnwrap_revertsWhenNotCalledByTheFactory() public {
        uint256 shares = _fundTopUpWithShares(DEPOSIT);

        vm.prank(anyone);
        vm.expectRevert(TopUp.OnlyOwner.selector);
        topUp.unwrap(address(svZchf), shares);
    }

    /// @dev The TopUp checks the registry itself, not only the factory. Unreachable through the
    ///      factory (which checks first), so it takes impersonating the factory to exercise —
    ///      but it is what stops a future factory path from making a TopUp call `redeem` on an
    ///      arbitrary address.
    function test_topUpUnwrap_refusesAnUnregisteredVaultEvenFromTheFactory() public {
        _fundTopUpWithShares(DEPOSIT);

        vm.prank(address(factory));
        vm.expectRevert(TopUp.VaultNotUnwrappable.selector);
        topUp.unwrap(address(weth), 1 ether);
    }

    /// @dev The registry verifies the pairing rather than trusting it, so a vault whose `asset()`
    ///      disagrees with the admin's claim cannot be registered.
    function test_setUnwrapVaults_revertsWhenTheVaultDisagreesAboutItsAsset() public {
        MismatchedVault liar = new MismatchedVault(address(weth));

        vm.prank(owner);
        vm.expectRevert(TopUpFactory.InvalidUnwrapVault.selector);
        _registerUnwrapVault(address(liar), address(zchf));
    }

    /// @dev A non-4626 target has no `asset()` at all, so registration reverts rather than
    ///      recording an unusable entry.
    function test_setUnwrapVaults_revertsForANonVaultTarget() public {
        vm.prank(owner);
        vm.expectRevert();
        _registerUnwrapVault(address(zchf), address(zchf));
    }

    function test_setUnwrapVaults_zeroAssetClearsTheEntry() public {
        vm.prank(owner);
        _registerUnwrapVault(address(svZchf), address(0));

        assertEq(factory.unwrapAssetFor(address(svZchf)), address(0), "entry should be cleared");

        uint256 shares = _fundTopUpWithShares(DEPOSIT);
        vm.expectRevert(TopUpFactory.VaultNotUnwrappable.selector);
        factory.unwrap(address(topUp), address(svZchf), shares);
    }

    function test_setUnwrapVaults_revertsForNonOwner() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(svZchf);
        address[] memory assets = new address[](1);
        assets[0] = address(zchf);

        vm.prank(anyone);
        vm.expectRevert();
        factory.setUnwrapVaults(vaults, assets);
    }

    function test_setUnwrapVaults_revertsOnArrayLengthMismatch() public {
        address[] memory vaults = new address[](2);
        vaults[0] = address(svZchf);
        vaults[1] = address(svZchf);
        address[] memory assets = new address[](1);
        assets[0] = address(zchf);

        vm.prank(owner);
        vm.expectRevert(TopUpFactory.ArrayLengthMismatch.selector);
        factory.setUnwrapVaults(vaults, assets);
    }

    /// @dev Finds the factory's `Unwrap` log and asserts every field of it. Read back rather than
    ///      matched with expectEmit, since the vault emits its own `Withdraw` first.
    function _assertUnwrapLog(Vm.Log[] memory logs, address topUp_, address vault, address asset, uint256 shares, uint256 assets) internal view {
        bytes32 topic = keccak256("Unwrap(address,address,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(factory) || logs[i].topics.length == 0 || logs[i].topics[0] != topic) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), topUp_, "Unwrap topUp");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), vault, "Unwrap vault");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), asset, "Unwrap asset");
            (uint256 loggedShares, uint256 loggedAssets) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(loggedShares, shares, "Unwrap shares");
            assertEq(loggedAssets, assets, "Unwrap assets");
            return;
        }
        assertTrue(false, "factory did not emit Unwrap");
    }
}
