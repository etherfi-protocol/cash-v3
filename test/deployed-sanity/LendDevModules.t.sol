// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ILayerZeroTeller } from "../../src/interfaces/ILayerZeroTeller.sol";
import { IOpenOceanCaller, IOpenOceanRouter, OpenOceanSwapDescription } from "../../src/interfaces/IOpenOcean.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiStakeModule } from "../../src/modules/etherfi/EtherFiStakeModule.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { EtherFiSafe } from "../../src/safe/EtherFiSafe.sol";
import { LendDevTestBase } from "./LendDevTestBase.t.sol";

/// @dev Stand-in for the liquid vault, etched over the real liquidUSD token on the fork: an ERC20 receipt
///      that doubles as its own teller, so a deposit pulls the underlying and mints receipt shares. Mirrors
///      the MockLiquidVault the lend suite uses; only the receipt-token decimals are taken from the real token.
contract LiquidVaultStub is ERC20 {
    uint8 internal immutable RECEIPT_DECIMALS;

    constructor(uint8 decimals_) ERC20("Liquid USD stub", "sLiquidUSD") {
        RECEIPT_DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return RECEIPT_DECIMALS;
    }

    function vault() external view returns (address) {
        return address(this);
    }

    function assetData(ERC20) external pure returns (ILayerZeroTeller.Asset memory) {
        return ILayerZeroTeller.Asset({ allowDeposits: true, allowWithdraws: true, sharePremium: 0 });
    }

    /// @dev Pulls the deposit asset (approved to this contract, as the module approves the liquid asset)
    ///      and mints usd-equivalent receipt shares.
    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256) public payable returns (uint256) {
        depositAsset.transferFrom(msg.sender, address(this), depositAmount);
        uint256 shares = depositAmount * 10 ** RECEIPT_DECIMALS / 10 ** IERC20Metadata(address(depositAsset)).decimals();
        _mint(msg.sender, shares);
        return shares;
    }

    /// @dev The referrer-flavored teller deposit used by the WithReferrer module variant.
    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint, address) external payable returns (uint256) {
        return deposit(depositAsset, depositAmount, minimumMint);
    }
}

/// @dev Sync-pool stub etched over the live pool: returns pre-dealt weETH 1:1 for the staked WETH.
contract SyncPoolStub {
    IERC20 internal immutable WEETH;

    constructor(address weeth) {
        WEETH = IERC20(weeth);
    }

    function deposit(address, uint256 amountIn, uint256) external payable returns (uint256) {
        WEETH.transfer(msg.sender, amountIn);
        return amountIn;
    }

    receive() external payable { }
}

/// @dev Custodian stub etched over the live Frax custodian: pulls the 6-decimal asset from the receiver
///      and pays out pre-dealt 18-decimal frxUSD 1:1e12.
contract FraxCustodianStub {
    IERC20 internal immutable FRAXUSD;
    IERC20 internal immutable ASSET;

    constructor(address fraxusd, address asset) {
        FRAXUSD = IERC20(fraxusd);
        ASSET = IERC20(asset);
    }

    function deposit(uint256 amountIn, address receiver) external payable returns (uint256) {
        ASSET.transferFrom(receiver, address(this), amountIn);
        uint256 shares = amountIn * 1e12;
        FRAXUSD.transfer(receiver, shares);
        return shares;
    }
}

/// @dev Midas deposit-vault stub etched over the live vault: pulls the approved asset and pays out
///      pre-dealt midas tokens usd-for-usd (scaled by decimals).
contract MidasVaultStub {
    IERC20 internal immutable MIDAS_TOKEN;
    uint8 internal immutable MIDAS_DECIMALS;

    constructor(address midasToken, uint8 midasDecimals) {
        MIDAS_TOKEN = IERC20(midasToken);
        MIDAS_DECIMALS = midasDecimals;
    }

    function depositInstant(address tokenIn, uint256 amountToken, uint256, bytes32) external {
        uint256 pull = IERC20(tokenIn).allowance(msg.sender, address(this));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), pull);
        uint256 payout = pull * 10 ** MIDAS_DECIMALS / 10 ** IERC20Metadata(tokenIn).decimals();
        payout = payout > amountToken ? payout : amountToken;
        MIDAS_TOKEN.transfer(msg.sender, payout);
    }
}

/// @dev beHYPE staker stub etched over the live staker: escrows the WHYPE (beHYPE arrives async in prod).
contract BeHypeStakerStub {
    IERC20 internal immutable WHYPE;

    constructor(address whype) {
        WHYPE = IERC20(whype);
    }

    function quoteStake(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function stake(uint256 hypeAmountIn, address) external payable {
        WHYPE.transferFrom(msg.sender, address(this), hypeAmountIn);
    }
}

/// @dev Swap-router stub etched over the live OpenOcean router, speaking the real router's swap signature
///      (the module validates the calldata's swap description): pulls the described input and pays out the
///      pre-dealt output to the described receiver.
contract SwapRouterStub {
    function swap(IOpenOceanCaller, OpenOceanSwapDescription calldata desc, IOpenOceanCaller.CallDescription[] calldata) external payable returns (uint256) {
        desc.srcToken.transferFrom(msg.sender, address(this), desc.amount);
        desc.dstToken.transfer(desc.dstReceiver, desc.minReturnAmount);
        return desc.minReturnAmount;
    }
}

/**
 * @title LendDevModulesTest
 * @notice One live operation through every deployed lend module (the wiring charter): each test drives the
 *         module's primary op on a gateway safe, with the module, gateway, and Aave legs real and only the
 *         external protocol etched over with a stub at its live address.
 */
contract LendDevModulesTest is LendDevTestBase {
    using MessageHashUtils for bytes32;

    /// A liquid deposit runs the full sandwich: the underlying is withdrawn from Aave, deposited into the
    /// vault (stubbed over liquidUSD), and the receipt is re-supplied to Aave.
    function test_liquid_depositRunsSandwich() public {
        _liquidDepositSandwich(liquidModule, "lend-dev-mod-liquid");
    }

    /// The referrer variant of the liquid module runs the same sandwich through its own deployed copy.
    function test_liquidReferrer_depositRunsSandwich() public {
        EtherFiLiquidModule referrer = EtherFiLiquidModule(payable(stdJson.readAddress(lendJson, ".newModules.liquidReferrer")));
        _liquidDepositSandwich(referrer, "lend-dev-mod-liquid-ref");
    }

    /// A stake deposit sources WETH from Aave, stakes through the (stubbed) sync pool, and re-supplies
    /// the weETH output.
    function test_stake_depositRunsSandwich() public {
        EtherFiStakeModule stakeModule = EtherFiStakeModule(payable(stdJson.readAddress(lendJson, ".newModules.stake")));
        address weth = stakeModule.weth();
        address pool = address(stakeModule.syncPool());
        vm.etch(pool, address(new SyncPoolStub(address(weETH))).code);
        deal(address(weETH), pool, 10 ether);

        address safe = _deploySafe("lend-dev-mod-stake", true);
        deal(weth, safe, 1 ether);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(weth));
        // Stake what actually sits supplied: WETH accrues on dev, so suppliedOf can round a wei
        // under the dealt amount and a hard-coded 1 ether would overdraw the sandwich's withdraw leg
        uint256 staked = gw.suppliedOf(safe, weth);
        assertApproxEqAbs(staked, 1 ether, 2, "WETH starts supplied");

        bytes memory sig = _moduleOpSig(address(stakeModule), stakeModule.DEPOSIT_SIG(), safe, abi.encode(weth, staked, staked));
        stakeModule.deposit(safe, weth, staked, staked, ownerA, sig);

        assertApproxEqAbs(gw.suppliedOf(safe, weth), 0, 2, "WETH withdrawn from Aave");
        assertApproxEqAbs(gw.suppliedOf(safe, address(weETH)), staked, 2, "weETH re-supplied to Aave");
    }

    /// A frax deposit sources USDC from Aave, mints through the (stubbed) custodian, and re-supplies the
    /// frxUSD output.
    function test_frax_depositRunsSandwich() public {
        FraxModule fraxModule = FraxModule(payable(stdJson.readAddress(lendJson, ".newModules.frax")));
        address fraxUsd = fraxModule.fraxusd();
        address custodian = fraxModule.custodian();
        vm.etch(custodian, address(new FraxCustodianStub(fraxUsd, address(usdc))).code);
        deal(fraxUsd, custodian, 1_000_000e18);

        address safe = _deploySafe("lend-dev-mod-frax", true);
        deal(address(usdc), safe, 60e6);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));

        uint256 custodianBefore = usdc.balanceOf(custodian);
        bytes memory sig = _moduleOpSig(address(fraxModule), fraxModule.DEPOSIT_SIG(), safe, abi.encode(address(usdc), uint256(50e6), uint256(50e18)));
        fraxModule.deposit(safe, address(usdc), 50e6, 50e18, ownerA, sig);

        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), 10e6, 2, "USDC withdrawn from Aave");
        assertEq(usdc.balanceOf(custodian), custodianBefore + 50e6, "USDC reached the custodian");
        assertApproxEqAbs(gw.suppliedOf(safe, fraxUsd), 50e18, 2, "frxUSD re-supplied to Aave");
    }

    /// A midas deposit sources USDC from Aave, issues through the (stubbed) deposit vault, and re-supplies
    /// the midas token (liquidRESERVE on dev).
    function test_midas_depositRunsSandwich() public {
        MidasModule midasModule = MidasModule(payable(stdJson.readAddress(lendJson, ".newModules.midas")));
        address midasToken = _reserveBySymbol("liquidRESERVE");
        (address depositVault,) = midasModule.vaults(midasToken);
        require(depositVault != address(0), "midas vault not configured for liquidRESERVE");
        uint8 midasDecimals = IERC20Metadata(midasToken).decimals();
        vm.etch(depositVault, address(new MidasVaultStub(midasToken, midasDecimals)).code);
        deal(midasToken, depositVault, 1_000_000 * 10 ** midasDecimals);

        address safe = _deploySafe("lend-dev-mod-midas", true);
        deal(address(usdc), safe, 60e6);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));

        bytes memory sig = _moduleOpSig(address(midasModule), midasModule.DEPOSIT_SIG(), safe, abi.encode(address(usdc), midasToken, uint256(50e6), uint256(1)));
        midasModule.deposit(safe, address(usdc), midasToken, 50e6, 1, ownerA, sig);

        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), 10e6, 2, "USDC withdrawn from Aave");
        assertGt(gw.suppliedOf(safe, midasToken), 0, "midas token re-supplied to Aave");
    }

    /// A beHYPE stake sources WHYPE from Aave and hands it to the (stubbed) staker; the beHYPE output is
    /// asynchronous in production, so nothing is re-supplied.
    function test_beHype_stakeRunsWithdrawLeg() public {
        BeHYPEStakeModule stakeModule = BeHYPEStakeModule(payable(stdJson.readAddress(lendJson, ".newModules.beHype")));
        address whype = stakeModule.whype();
        address staker = address(stakeModule.staker());
        vm.etch(staker, address(new BeHypeStakerStub(whype)).code);

        address safe = _deploySafe("lend-dev-mod-behype", true);
        deal(whype, safe, 1 ether);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(whype));
        // Stake what actually sits supplied: once WHYPE accrues, suppliedOf can round a wei under
        // the dealt amount and a hard-coded 1 ether would overdraw the withdraw leg
        uint256 staked = gw.suppliedOf(safe, whype);
        assertApproxEqAbs(staked, 1 ether, 2, "WHYPE starts supplied");

        bytes memory sig = _moduleOpSig(address(stakeModule), stakeModule.STAKE_SIG(), safe, abi.encode(staked));
        stakeModule.stake(safe, staked, ownerA, sig);

        assertApproxEqAbs(gw.suppliedOf(safe, whype), 0, 2, "WHYPE withdrawn from Aave");
        assertEq(IERC20(whype).balanceOf(staker), staked, "WHYPE staked with the staker");
    }

    /// A swap sources its input from Aave, swaps through the (stubbed) OpenOcean router, and re-supplies
    /// the output.
    function test_openOcean_swapRunsSandwich() public {
        OpenOceanSwapModule swapModule = OpenOceanSwapModule(payable(stdJson.readAddress(lendJson, ".newModules.openOcean")));
        address router = swapModule.swapRouter();
        IERC20 usdt = IERC20(_reserveBySymbol("USDT"));
        vm.etch(router, address(new SwapRouterStub()).code);
        deal(address(usdt), router, 1_000_000e6);

        address safe = _deploySafe("lend-dev-mod-swap", true);
        deal(address(usdc), safe, 60e6);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));

        bytes memory swapData = _openOceanSwapData(safe, address(usdt));
        swapModule.swap(safe, address(usdc), address(usdt), 50e6, 1, swapData, _signers(), _swapSigs(swapModule, safe, address(usdt), swapData));

        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), 10e6, 2, "USDC withdrawn from Aave");
        assertApproxEqAbs(gw.suppliedOf(safe, address(usdt)), 50e6, 2, "USDT output re-supplied to Aave");
    }

    /// The liquifier repays a gateway safe's USDC debt from its float and reclaims supplied liquidUSD:
    /// debt drops, the safe's supplied liquidUSD is pulled, and the liquifier holds the reclaimed amount.
    function test_liquifier_repayReducesDebtUsingSuppliedLiquidUsd() public {
        LiquidUSDLiquifierOPModule liquifier = LiquidUSDLiquifierOPModule(stdJson.readAddress(baseJson, ".addresses.LiquidUSDLiquifierModule"));
        IERC20 liquidUsd = liquifier.LIQUID_USD();
        _seedAaveUsdcLiquidity();

        address safe = _deploySafe("lend-dev-mod-liquifier", true);
        deal(address(weETH), safe, 1 ether);
        deal(address(liquidUsd), safe, 100e6);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(weETH)));
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(liquidUsd)));
        assertGt(gw.suppliedOf(safe, address(liquidUsd)), 0, "liquidUSD starts supplied");

        uint256 borrowUsd = gw.getAccountData(safe).availableBorrowsUsd / 4;
        cashModule.borrow(safe, address(usdc), borrowUsd, _signers(), _borrowSigs(safe, address(usdc), borrowUsd));
        uint256 debtBefore = gw.debtOf(safe, address(usdc));
        assertGt(debtBefore, 0, "safe has USDC debt");

        deal(address(usdc), address(liquifier), 1000e6);
        uint256 suppliedLiquidBefore = gw.suppliedOf(safe, address(liquidUsd));
        vm.prank(devAdmin);
        liquifier.repayUsingLiquidUSD(safe, 20e6);

        assertApproxEqAbs(gw.debtOf(safe, address(usdc)), debtBefore - 20e6, 2, "repay reduced the Aave debt");
        assertLt(gw.suppliedOf(safe, address(liquidUsd)), suppliedLiquidBefore, "supplied liquidUSD reclaimed");
        assertGt(liquidUsd.balanceOf(address(liquifier)), 0, "liquifier holds the reclaimed liquidUSD");
    }

    // ----------------------------------------------------------------- helpers

    /// @dev Runs the deposit sandwich through `module` (the liquid module or its referrer variant), with the
    ///      vault stub etched over the real liquidUSD token.
    function _liquidDepositSandwich(EtherFiLiquidModule module, bytes32 salt) internal {
        address liquidUsd = _etchLiquidVaultStub(module);

        address safe = _deploySafe(salt, true);
        deal(address(usdc), safe, 100e6);
        vm.prank(devAdmin);
        cashModule.supplyToLend(safe, _addr1(address(usdc)));
        assertEq(usdc.balanceOf(safe), 0, "underlying starts fully supplied");

        uint256 vaultUsdcBefore = usdc.balanceOf(liquidUsd);
        uint256 shares = 90e6 * 10 ** IERC20Metadata(liquidUsd).decimals() / 1e6;
        bytes memory sig = _moduleOpSig(address(module), module.DEPOSIT_SIG(), safe, abi.encode(address(usdc), liquidUsd, uint256(90e6), shares / 2));
        module.deposit(safe, address(usdc), liquidUsd, 90e6, shares / 2, ownerA, sig);

        // withdraw leg: the underlying came out of Aave; act leg: it reached the vault;
        // re-supply leg: the receipt went back in
        assertApproxEqAbs(gw.suppliedOf(safe, address(usdc)), 10e6, 2, "underlying withdrawn from Aave");
        assertEq(usdc.balanceOf(liquidUsd), vaultUsdcBefore + 90e6, "underlying deposited into the vault");
        assertApproxEqAbs(gw.suppliedOf(safe, liquidUsd), shares, 2, "receipt re-supplied to Aave");
        assertEq(IERC20(liquidUsd).balanceOf(safe), 0, "receipt not left loose");
    }

    /// @dev Etches the vault stub over the real liquidUSD token and wires it as its own teller on `module`.
    ///      The Aave hub checks its token balance against its internal ledger on every supply, and the etch
    ///      replaces the token's storage view, so the hub's real balance is mirrored onto the stub first —
    ///      otherwise every resupply reverts once anyone has really supplied liquidUSD on dev.
    function _etchLiquidVaultStub(EtherFiLiquidModule module) internal returns (address) {
        address liquidUsd = _findReserveByAssetId(liquidUsdAssetId);
        require(spoke.getReserve(gw.reserveIdOf(liquidUsd)).underlying == liquidUsd, "liquidUSD not registered on the gateway");
        address hub = spoke.getReserve(gw.reserveIdOf(liquidUsd)).hub;
        uint256 hubBalance = IERC20(liquidUsd).balanceOf(hub);
        vm.etch(liquidUsd, address(new LiquidVaultStub(IERC20Metadata(liquidUsd).decimals())).code);
        deal(liquidUsd, hub, hubBalance);
        if (address(module.liquidAssetToTeller(liquidUsd)) != liquidUsd) {
            bytes32 adminRole = module.ETHERFI_LIQUID_MODULE_ADMIN();
            vm.startPrank(devAdmin);
            registry.grantRole(adminRole, devAdmin);
            module.addLiquidAssets(_addr1(liquidUsd), _addr1(liquidUsd));
            vm.stopPrank();
        }
        return liquidUsd;
    }

    /// @dev Router calldata in the real OpenOcean shape (the module validates the description fields):
    ///      50e6 USDC in, 50e6 `toAsset` out to the safe.
    function _openOceanSwapData(address safe, address toAsset) internal view returns (bytes memory) {
        OpenOceanSwapDescription memory desc = OpenOceanSwapDescription({ srcToken: usdc, dstToken: IERC20(toAsset), srcReceiver: address(0), dstReceiver: payable(safe), amount: 50e6, minReturnAmount: 50e6, guaranteedAmount: 50e6, flags: 0, referrer: address(0), permit: "" });
        IOpenOceanCaller.CallDescription[] memory calls = new IOpenOceanCaller.CallDescription[](0);
        return abi.encodeCall(IOpenOceanRouter.swap, (IOpenOceanCaller(address(0)), desc, calls));
    }

    /// @dev Single-owner quorum signature for the swap page (USDC in, 50e6 for 1 minimum out, safe nonce).
    function _swapSigs(OpenOceanSwapModule swapModule, address safe, address toAsset, bytes memory swapData) internal view returns (bytes[] memory) {
        bytes32 digest = keccak256(abi.encodePacked(swapModule.SWAP_SIG(), block.chainid, address(swapModule), EtherFiSafe(payable(safe)).nonce(), safe, abi.encode(address(usdc), toAsset, uint256(50e6), uint256(1), swapData))).toEthSignedMessageHash();
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(digest);
        return sigs;
    }

    /// @dev Single-owner signature over a module-nonce op digest: keccak(sig, chainid, module, nonce, safe, params).
    function _moduleOpSig(address module, bytes32 sigConstant, address safe, bytes memory params) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(sigConstant, block.chainid, module, EtherFiLiquidModule(payable(module)).getNonce(safe), safe, params)).toEthSignedMessageHash();
        return _sign(digest);
    }
}
