// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { ILayerZeroTeller } from "../../src/interfaces/ILayerZeroTeller.sol";
import { ITradingSafeLiquidDepositModule } from "../../src/interfaces/ITradingSafeLiquidDepositModule.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";
import { ModuleBase } from "../../src/modules/ModuleBase.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiSafeErrors } from "../../src/safe/EtherFiSafeErrors.sol";
import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { TradingSafeLiquidDepositModule } from "../../src/trading-safe/TradingSafeLiquidDepositModule.sol";
import { TradingSafeTestBase } from "./TradingSafeTestBase.t.sol";

/// @dev Minimal stand-in for the Liquid BTC Veda BoringVault: the ERC20 share token that is also
///      the approved spender that pulls the deposit asset. Only the configured teller may `enter`.
contract MockBoringVault is ERC20 {
    address public teller;

    constructor() ERC20("Liquid BTC", "LBTC") { }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function setTeller(address _teller) external {
        teller = _teller;
    }

    /// @dev Pulls `pull` of `asset` from `from` (the safe, which approved this vault) and mints
    ///      `shares` to `to`. Splitting the pulled amount from the minted shares lets tests model a
    ///      teller that debits less than requested.
    function enter(address from, address asset, uint256 pull, address to, uint256 shares) external {
        require(msg.sender == teller, "only teller");
        MockERC20(asset).transferFrom(from, address(this), pull);
        _mint(to, shares);
    }
}

/// @dev Configurable Veda-style teller over `MockBoringVault`. Mirrors the parts the module reads:
///      `vault()`, `assetData().allowDeposits`, `shareLockPeriod()`, and a 3-arg `deposit`.
contract MockLiquidTeller {
    MockBoringVault public immutable vaultToken;
    bool public allowDeposits = true;
    uint64 public lockPeriod;

    // Mint rate as a 1e18 fraction of the deposited amount (default 1:1).
    uint256 public rate = 1e18;
    // When set, the teller pulls this much of the deposit asset instead of the full amount.
    uint256 public pullOverride;
    bool public usePullOverride;
    // When true, the teller skips its own minimum-mint check so the module's guard can be exercised.
    bool public skipMinCheck;

    constructor(MockBoringVault _vault) {
        vaultToken = _vault;
    }

    function setAllowDeposits(bool v) external {
        allowDeposits = v;
    }

    function setLockPeriod(uint64 v) external {
        lockPeriod = v;
    }

    function setRate(uint256 v) external {
        rate = v;
    }

    function setPullOverride(uint256 v) external {
        pullOverride = v;
        usePullOverride = true;
    }

    function setSkipMinCheck(bool v) external {
        skipMinCheck = v;
    }

    function vault() external view returns (address) {
        return address(vaultToken);
    }

    function assetData(ERC20) external view returns (ILayerZeroTeller.Asset memory) {
        return ILayerZeroTeller.Asset({ allowDeposits: allowDeposits, allowWithdraws: true, sharePremium: 0 });
    }

    function shareLockPeriod() external view returns (uint64) {
        return lockPeriod;
    }

    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint) external returns (uint256 shares) {
        shares = (depositAmount * rate) / 1e18;
        if (!skipMinCheck) require(shares >= minimumMint, "min");
        uint256 pull = usePullOverride ? pullOverride : depositAmount;
        vaultToken.enter(msg.sender, address(depositAsset), pull, msg.sender, shares);
    }
}

contract TradingSafeLiquidDepositModuleTest is TradingSafeTestBase {
    using MessageHashUtils for bytes32;

    TradingSafeFactory internal factory;
    TradingSafeLiquidDepositModule internal module;
    TradingSafe internal safe;

    MockERC20 internal wbtc;
    MockBoringVault internal liquidBtc;
    MockLiquidTeller internal teller;

    address internal safeAddr;
    address internal topUp; // factory-resolved TopUp (== sourceSafe here)
    address internal relayer = makeAddr("relayer");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal sourceSafe = makeAddr("sourceSafe");

    address internal owner1;
    uint256 internal owner1Pk;
    address internal owner2;
    uint256 internal owner2Pk;

    uint256 internal constant DEADLINE = type(uint256).max;
    uint256 internal constant WBTC_UNIT = 1e8;

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

        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);
        liquidBtc = new MockBoringVault();
        teller = new MockLiquidTeller(liquidBtc);
        liquidBtc.setTeller(address(teller));

        module = new TradingSafeLiquidDepositModule(address(dataProvider), address(wbtc), address(liquidBtc), address(teller));

        // Register as a DEFAULT module so it is enabled on every TradingSafe automatically.
        address[] memory mods = new address[](1);
        mods[0] = address(module);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        dataProvider.configureDefaultModules(mods, flags);

        address[] memory initialOwners = new address[](2);
        initialOwners[0] = owner1;
        initialOwners[1] = owner2;
        safe = _deployTradingSafe(factory, sourceSafe, initialOwners, 2);
        safeAddr = address(safe);
        vm.stopPrank();

        topUp = factory.getTopUpAddress(safeAddr);
    }

    // ---- Constructor validation ----

    function test_constructor_revertsOnZeroConfig() public {
        vm.expectRevert(ITradingSafeLiquidDepositModule.InvalidConfiguration.selector);
        new TradingSafeLiquidDepositModule(address(dataProvider), address(0), address(liquidBtc), address(teller));
    }

    function test_constructor_revertsIfTellerVaultMismatch() public {
        MockBoringVault otherVault = new MockBoringVault();
        vm.expectRevert(ITradingSafeLiquidDepositModule.InvalidConfiguration.selector);
        new TradingSafeLiquidDepositModule(address(dataProvider), address(wbtc), address(otherVault), address(teller));
    }

    // ---- Happy path ----

    function test_deposit_mintsLiquidBtcAndForwardsToTopUp() public {
        uint256 amount = 2 * WBTC_UNIT;
        wbtc.mint(safeAddr, amount);

        (address[] memory signers, bytes[] memory sigs) = _sign(amount, amount, DEADLINE);

        vm.expectEmit(true, true, true, true, address(module));
        emit ITradingSafeLiquidDepositModule.DepositedToTopUp(safeAddr, topUp, amount, amount);

        // Permissionless relay: an arbitrary caller submits the owner-signed authorization.
        vm.prank(relayer);
        module.depositToTopUp(safeAddr, amount, amount, DEADLINE, signers, sigs);

        assertEq(wbtc.balanceOf(safeAddr), 0, "all WBTC deposited");
        assertEq(liquidBtc.balanceOf(topUp), amount, "TopUp credited minted Liquid BTC");
        assertEq(liquidBtc.balanceOf(safeAddr), 0, "no Liquid BTC lingers in safe");
        assertEq(wbtc.allowance(safeAddr, address(liquidBtc)), 0, "deposit allowance reset");
    }

    function test_deposit_partialAmountKeepsRemainder() public {
        uint256 held = 5 * WBTC_UNIT;
        uint256 amount = 2 * WBTC_UNIT;
        wbtc.mint(safeAddr, held);

        (address[] memory signers, bytes[] memory sigs) = _sign(amount, amount, DEADLINE);
        vm.prank(relayer);
        module.depositToTopUp(safeAddr, amount, amount, DEADLINE, signers, sigs);

        assertEq(wbtc.balanceOf(safeAddr), held - amount, "unspent WBTC kept");
        assertEq(liquidBtc.balanceOf(topUp), amount, "TopUp credited");
    }

    /// @dev Pre-existing Liquid BTC in the safe must be left untouched; only the freshly minted
    ///      delta is forwarded.
    function test_deposit_forwardsOnlyMintedDelta() public {
        uint256 preexisting = 3 * WBTC_UNIT;
        deal(address(liquidBtc), safeAddr, preexisting);

        uint256 amount = 1 * WBTC_UNIT;
        wbtc.mint(safeAddr, amount);

        (address[] memory signers, bytes[] memory sigs) = _sign(amount, amount, DEADLINE);
        vm.prank(relayer);
        module.depositToTopUp(safeAddr, amount, amount, DEADLINE, signers, sigs);

        assertEq(liquidBtc.balanceOf(safeAddr), preexisting, "pre-existing Liquid BTC untouched");
        assertEq(liquidBtc.balanceOf(topUp), amount, "only minted delta forwarded");
    }

    // ---- Amount / slippage validation ----

    function test_deposit_revertsIfAmountZero() public {
        (address[] memory signers, bytes[] memory sigs) = _sign(0, 1, DEADLINE);
        vm.expectRevert(ITradingSafeLiquidDepositModule.InvalidAmount.selector);
        module.depositToTopUp(safeAddr, 0, 1, DEADLINE, signers, sigs);
    }

    function test_deposit_revertsIfMinReturnZero() public {
        wbtc.mint(safeAddr, WBTC_UNIT);
        (address[] memory signers, bytes[] memory sigs) = _sign(WBTC_UNIT, 0, DEADLINE);
        vm.expectRevert(ITradingSafeLiquidDepositModule.InvalidMinReturn.selector);
        module.depositToTopUp(safeAddr, WBTC_UNIT, 0, DEADLINE, signers, sigs);
    }

    function test_deposit_revertsIfInsufficientBalance() public {
        wbtc.mint(safeAddr, WBTC_UNIT);
        (address[] memory signers, bytes[] memory sigs) = _sign(2 * WBTC_UNIT, 2 * WBTC_UNIT, DEADLINE);
        vm.expectRevert(ITradingSafeLiquidDepositModule.InsufficientBalance.selector);
        module.depositToTopUp(safeAddr, 2 * WBTC_UNIT, 2 * WBTC_UNIT, DEADLINE, signers, sigs);
    }

    /// @dev Module's own minimum-output guard, exercised by making the teller skip its own check and
    ///      mint below the signed minimum.
    function test_deposit_revertsIfMintedBelowMinimum() public {
        teller.setSkipMinCheck(true);
        teller.setRate(0.5e18); // mints half the deposit

        uint256 amount = 2 * WBTC_UNIT;
        wbtc.mint(safeAddr, amount);
        (address[] memory signers, bytes[] memory sigs) = _sign(amount, amount, DEADLINE);
        vm.expectRevert(ITradingSafeLiquidDepositModule.InsufficientReturnAmount.selector);
        module.depositToTopUp(safeAddr, amount, amount, DEADLINE, signers, sigs);
    }

    /// @dev Asserts the exact-WBTC-debit guard: a teller that pulls less than requested is rejected.
    function test_deposit_revertsIfWbtcDebitInexact() public {
        uint256 amount = 2 * WBTC_UNIT;
        teller.setPullOverride(amount - 1);
        wbtc.mint(safeAddr, amount);
        (address[] memory signers, bytes[] memory sigs) = _sign(amount, 1, DEADLINE);
        vm.expectRevert(ITradingSafeLiquidDepositModule.DepositTransferFailed.selector);
        module.depositToTopUp(safeAddr, amount, 1, DEADLINE, signers, sigs);
    }

    // ---- Teller readiness ----

    function test_deposit_revertsIfDepositsDisabled() public {
        teller.setAllowDeposits(false);
        wbtc.mint(safeAddr, WBTC_UNIT);
        (address[] memory signers, bytes[] memory sigs) = _sign(WBTC_UNIT, WBTC_UNIT, DEADLINE);
        vm.expectRevert(ITradingSafeLiquidDepositModule.DepositAssetNotAllowed.selector);
        module.depositToTopUp(safeAddr, WBTC_UNIT, WBTC_UNIT, DEADLINE, signers, sigs);
    }

    function test_deposit_revertsIfSharesLocked() public {
        teller.setLockPeriod(1);
        wbtc.mint(safeAddr, WBTC_UNIT);
        (address[] memory signers, bytes[] memory sigs) = _sign(WBTC_UNIT, WBTC_UNIT, DEADLINE);
        vm.expectRevert(ITradingSafeLiquidDepositModule.SharesLocked.selector);
        module.depositToTopUp(safeAddr, WBTC_UNIT, WBTC_UNIT, DEADLINE, signers, sigs);
    }

    // ---- Signature / replay / authorization ----

    function test_deposit_revertsIfExpired() public {
        wbtc.mint(safeAddr, WBTC_UNIT);
        uint256 deadline = block.timestamp + 1 hours;
        (address[] memory signers, bytes[] memory sigs) = _sign(WBTC_UNIT, WBTC_UNIT, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(ITradingSafeLiquidDepositModule.DepositExpired.selector);
        module.depositToTopUp(safeAddr, WBTC_UNIT, WBTC_UNIT, deadline, signers, sigs);
    }

    function test_deposit_revertsIfSignatureOverDifferentAmount() public {
        wbtc.mint(safeAddr, 3 * WBTC_UNIT);
        (address[] memory signers, bytes[] memory sigs) = _sign(WBTC_UNIT, WBTC_UNIT, DEADLINE);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.depositToTopUp(safeAddr, 2 * WBTC_UNIT, WBTC_UNIT, DEADLINE, signers, sigs);
    }

    function test_deposit_revertsOnNonceReplay() public {
        wbtc.mint(safeAddr, 4 * WBTC_UNIT);
        (address[] memory signers, bytes[] memory sigs) = _sign(2 * WBTC_UNIT, 2 * WBTC_UNIT, DEADLINE);

        module.depositToTopUp(safeAddr, 2 * WBTC_UNIT, 2 * WBTC_UNIT, DEADLINE, signers, sigs);
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        module.depositToTopUp(safeAddr, 2 * WBTC_UNIT, 2 * WBTC_UNIT, DEADLINE, signers, sigs);
    }

    function test_deposit_revertsIfBelowThreshold() public {
        wbtc.mint(safeAddr, 2 * WBTC_UNIT);
        (, bytes[] memory fullSigs) = _sign(WBTC_UNIT, WBTC_UNIT, DEADLINE);

        address[] memory oneSigner = new address[](1);
        oneSigner[0] = owner1;
        bytes[] memory oneSig = new bytes[](1);
        oneSig[0] = fullSigs[0];

        vm.expectRevert(EtherFiSafeErrors.InsufficientSigners.selector);
        module.depositToTopUp(safeAddr, WBTC_UNIT, WBTC_UNIT, DEADLINE, oneSigner, oneSig);
    }

    function test_deposit_revertsForNonTradingSafe() public {
        address notASafe = makeAddr("notASafe");
        (address[] memory signers, bytes[] memory sigs) = _sign(WBTC_UNIT, WBTC_UNIT, DEADLINE);
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        module.depositToTopUp(notASafe, WBTC_UNIT, WBTC_UNIT, DEADLINE, signers, sigs);
    }

    // ---- Module enablement ----

    function test_deposit_revertsIfModuleNotEnabledOnSafe() public {
        TradingSafeLiquidDepositModule module2 = new TradingSafeLiquidDepositModule(address(dataProvider), address(wbtc), address(liquidBtc), address(teller));
        address[] memory mods = new address[](1);
        mods[0] = address(module2);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        vm.prank(owner);
        dataProvider.configureModules(mods, flags);

        wbtc.mint(safeAddr, WBTC_UNIT);
        (address[] memory signers, bytes[] memory sigs) = _signFor(address(module2), WBTC_UNIT, WBTC_UNIT, DEADLINE);
        vm.expectRevert(EtherFiSafeErrors.OnlyModules.selector);
        module2.depositToTopUp(safeAddr, WBTC_UNIT, WBTC_UNIT, DEADLINE, signers, sigs);
    }

    // ---- Pause ----

    function test_deposit_revertsWhenPaused() public {
        vm.prank(pauser);
        module.pause();

        wbtc.mint(safeAddr, WBTC_UNIT);
        (address[] memory signers, bytes[] memory sigs) = _sign(WBTC_UNIT, WBTC_UNIT, DEADLINE);
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        module.depositToTopUp(safeAddr, WBTC_UNIT, WBTC_UNIT, DEADLINE, signers, sigs);
    }

    function test_pause_onlyPauser() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(RoleRegistry.OnlyPauser.selector);
        module.pause();
    }

    function test_unpause_onlyUnpauserAndResumes() public {
        vm.prank(pauser);
        module.pause();

        vm.prank(makeAddr("random"));
        vm.expectRevert(RoleRegistry.OnlyUnpauser.selector);
        module.unpause();

        vm.prank(unpauser);
        module.unpause();

        wbtc.mint(safeAddr, WBTC_UNIT);
        (address[] memory signers, bytes[] memory sigs) = _sign(WBTC_UNIT, WBTC_UNIT, DEADLINE);
        module.depositToTopUp(safeAddr, WBTC_UNIT, WBTC_UNIT, DEADLINE, signers, sigs);
        assertEq(liquidBtc.balanceOf(topUp), WBTC_UNIT, "deposit resumes after unpause");
    }

    // --- helpers ---

    function _sign(uint256 amount, uint256 minReturn, uint256 deadline) internal view returns (address[] memory signers, bytes[] memory sigs) {
        return _signFor(address(module), amount, minReturn, deadline);
    }

    function _signFor(address module_, uint256 amount, uint256 minReturn, uint256 deadline) internal view returns (address[] memory signers, bytes[] memory sigs) {
        bytes32 digest = keccak256(abi.encodePacked(keccak256("TradingSafeLiquidDepositModule.depositToTopUp"), block.chainid, module_, safe.nonce(), safeAddr, topUp, amount, minReturn, deadline)).toEthSignedMessageHash();

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
