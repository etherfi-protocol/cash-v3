// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { EtherFiLiquidModule } from "../../../../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { LendGateway } from "../../../../../src/modules/lend-gateway/LendGateway.sol";
import { ILayerZeroTeller, BoringVault } from "../../../../../src/interfaces/ILayerZeroTeller.sol";
import { ModuleLendGatewaySandwich } from "../../../../../src/modules/ModuleLendGatewaySandwich.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";
import { ISpoke } from "aave-v4/spoke/interfaces/ISpoke.sol";

/// @dev Vault and teller in one: an ERC20 receipt whose deposit pulls the underlying (approved to this
///      contract, as the module approves the liquid asset) and mints receipt shares 1:1.
contract MockLiquidVault is ERC20 {
    constructor() ERC20("Mock Liquid USD", "mLiquidUSD") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function vault() external view returns (BoringVault) {
        return BoringVault(address(this));
    }

    function assetData(ERC20) external pure returns (ILayerZeroTeller.Asset memory) {
        return ILayerZeroTeller.Asset({ allowDeposits: true, allowWithdraws: true, sharePremium: 0 });
    }

    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256) external payable returns (uint256) {
        depositAsset.transferFrom(msg.sender, address(this), depositAmount);
        _mint(msg.sender, depositAmount);
        return depositAmount;
    }
}

/// @dev Boring queue stub: quotes 1:1 and escrows the shares pulled from the requester.
contract MockBoringQueue {
    address public immutable boringVault;

    constructor(address _vault) {
        boringVault = _vault;
    }

    function previewAssetsOut(address, uint128 amountOfShares, uint16) external pure returns (uint128) {
        return amountOfShares;
    }

    function requestOnChainWithdraw(address, uint128 amountOfShares, uint16, uint24) external returns (bytes32) {
        IERC20(boringVault).transferFrom(msg.sender, address(this), amountOfShares);
        return bytes32(0);
    }
}

/**
 * @title EtherFiLiquidGatewayTest
 * @notice Exercises the liquid module's Aave sandwich against the real LendGateway: a deposit's underlying is
 *         supplied to Aave, so the module withdraws it back, deposits into the vault, and re-supplies the
 *         receipt (registered as a reserve, matching LiquidUSD being listed); a queued withdrawal pulls the
 *         supplied receipt back out. The vault and queue are stubs; the gateway and Aave are real.
 */
contract EtherFiLiquidGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    EtherFiLiquidModule internal liquidModule;
    MockLiquidVault internal liquidVault;
    MockBoringQueue internal boringQueue;

    function setUp() public override {
        super.setUp();

        liquidVault = new MockLiquidVault();
        boringQueue = new MockBoringQueue(address(liquidVault));

        // The receipt token is a listed Aave reserve (the LiquidUSD-listed decision): $1-priced like USDC.
        uint256 liquidReserveId = _addAaveReserve(address(liquidVault), usdcUsdOracle, _usdcCollateralFactorBps(), false);

        liquidModule = new EtherFiLiquidModule(_addr1(address(liquidVault)), _addr1(address(liquidVault)), address(dataProvider), chainConfig.weth);
        _enableModule(address(liquidModule));

        vm.startPrank(owner);
        gw.setReserveId(address(liquidVault), liquidReserveId);
        // The sandwich drives gateway withdraw / supply on the safe's behalf, so it must be an authorized driver.
        gw.setDriver(address(liquidModule), true);
        roleRegistry.grantRole(liquidModule.ADMIN_ROLE(), owner);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidVault), address(boringQueue));
        vm.stopPrank();
    }

    // A deposit sources its underlying entirely from Aave: the module withdraws the supplied USDC, deposits
    // into the vault, and re-supplies the receipt as collateral. Nothing is left loose in the safe.
    function test_deposit_sourcesUnderlyingFromAaveAndResuppliesReceipt() public {
        uint256 amount = 1000e6;
        _supplyToGateway(address(safe), address(usdc), amount);
        uint256 usdcSuppliedBefore = gw.suppliedOf(address(safe), address(usdc));

        liquidModule.deposit(address(safe), address(usdc), address(liquidVault), amount, amount, owner1, _depositSig(address(usdc), amount, amount));

        assertEq(gw.suppliedOf(address(safe), address(usdc)), usdcSuppliedBefore - amount, "USDC not withdrawn from Aave");
        assertEq(gw.suppliedOf(address(safe), address(liquidVault)), amount, "receipt not re-supplied");
        assertEq(usdc.balanceOf(address(safe)), 0, "USDC left loose in safe");
        assertEq(liquidVault.balanceOf(address(safe)), 0, "receipt left loose in safe");
    }

    // A queued withdrawal pulls the supplied receipt out of Aave and escrows it in the queue.
    function test_withdraw_pullsSuppliedReceiptForQueue() public {
        uint128 amount = 500e6;
        _supplyToGateway(address(safe), address(liquidVault), amount);

        liquidModule.withdraw(address(safe), address(liquidVault), address(usdc), amount, amount, 0, 1 days, owner1, _withdrawSig(amount, amount, 0, 1 days));

        assertEq(gw.suppliedOf(address(safe), address(liquidVault)), 0, "receipt not withdrawn from Aave");
        assertEq(liquidVault.balanceOf(address(boringQueue)), amount, "receipt not escrowed in queue");
        assertEq(liquidVault.balanceOf(address(safe)), 0, "receipt left loose in safe");
    }

    // The sandwich is engine-gated, not opt-out-gated: a legacy safe has not opted out, yet its deposit must
    // not touch Aave — the receipt stays loose where the DebtManager can see it.
    function test_deposit_legacySafe_receiptStaysLoose() public {
        _forceLegacyEngine(address(safe));
        assertFalse(cashModule.isLendOptedOut(address(safe)), "fixture: a legacy safe has not opted out");
        assertFalse(cashModule.isLendActive(address(safe)), "fixture: a legacy safe is not lend-active");

        uint256 amount = 1000e6;
        deal(address(usdc), address(safe), amount);

        liquidModule.deposit(address(safe), address(usdc), address(liquidVault), amount, amount, owner1, _depositSig(address(usdc), amount, amount));

        assertEq(liquidVault.balanceOf(address(safe)), amount, "receipt must stay loose in the safe");
        assertEq(gw.suppliedOf(address(safe), address(liquidVault)), 0, "receipt must not be supplied to Aave");
    }

    // The receipt re-supply is best-effort: if the receipt's reserve is frozen, the deposit still completes
    // and the receipt stays loose in the safe for the next sweep, rather than reverting after the vault
    // deposit already ran.
    function test_deposit_receiptStaysLooseWhenReserveFrozen() public {
        uint256 amount = 1000e6;
        deal(address(usdc), address(safe), amount);

        // Freeze the receipt's reserve so Aave rejects the sandwich's re-supply of the minted receipt
        _setAaveReserveFrozen(gw.reserveIdOf(address(liquidVault)), true);

        bytes memory reason = abi.encodeWithSelector(ISpoke.ReserveFrozen.selector);
        vm.expectEmit(true, true, false, true, address(liquidModule));
        emit ModuleLendGatewaySandwich.LendSupplyFailed(address(safe), address(liquidVault), amount, reason);
        liquidModule.deposit(address(safe), address(usdc), address(liquidVault), amount, amount, owner1, _depositSig(address(usdc), amount, amount));

        assertEq(liquidVault.balanceOf(address(safe)), amount, "receipt stays loose when the re-supply is rejected");
        assertEq(gw.suppliedOf(address(safe), address(liquidVault)), 0, "nothing supplied to the frozen reserve");
    }

    // A queued withdrawal is a risk-increasing flow with no resupply (the receipt is escrowed away), so
    // its end state takes the gateway's health-factor floor: a pull Aave itself would allow (HF stays
    // >= 1) reverts when it lands below the floor, and a smaller pull clears it.
    function test_withdraw_takesGatewayHealthFactorFloor() public {
        _supplyToGateway(address(safe), address(liquidVault), 10_000e6);
        _borrowOnGateway(address(safe), address(usdc), 4000e6, recipient);
        vm.prank(owner);
        gw.setMinHealthFactor(1.05e18);

        // Aave allows up to 5000e6 out (HF -> 1.0); 4900e6 lands ~1.02, below the 1.05 floor
        uint128 tooMuch = 4900e6;
        bytes memory sig = _withdrawSig(tooMuch, tooMuch, 0, 1 days);
        vm.expectRevert(LendGateway.HealthFactorBelowMinimum.selector);
        liquidModule.withdraw(address(safe), address(liquidVault), address(usdc), tooMuch, tooMuch, 0, 1 days, owner1, sig);

        // 4000e6 lands HF = 0.8 * 6000 / 4000 = 1.2, above the floor
        uint128 fine = 4000e6;
        liquidModule.withdraw(address(safe), address(liquidVault), address(usdc), fine, fine, 0, 1 days, owner1, _withdrawSig(fine, fine, 0, 1 days));
        // Read the health factor from the spoke: the mock receipt has no PriceProvider oracle, so the
        // gateway's USD-deriving getAccountData cannot price it (the floor check itself is spoke-based)
        assertGe(spoke.getUserAccountData(address(safe)).healthFactor, 1.05e18, "end state above the floor");
    }

    // A safe parked between Aave's 1.00 bound and the floor is not frozen out of the sandwiched modules: an
    // operation that leaves its health no worse off still runs, because the floor is there to stop extraction
    // approaching the liquidation line, not to block a safe from improving. A deposit funded from loose
    // balance re-supplies the receipt as collateral, so it lifts health even while staying under the floor.
    function test_deposit_belowFloor_allowedWhenHealthImproves() public {
        _supplyToGateway(address(safe), address(liquidVault), 10_000e6);
        _borrowOnGateway(address(safe), address(usdc), 7800e6, recipient); // HF ~1.026
        vm.prank(owner);
        gw.setMinHealthFactor(1.05e18);

        uint256 hfBefore = gw.healthFactor(address(safe));
        assertLt(hfBefore, 1.05e18, "safe starts below the floor");
        assertGt(hfBefore, 1e18, "and above Aave's bound");

        // Loose USDC in, receipt back as collateral: strictly more collateral, same debt
        uint256 amount = 100e6;
        deal(address(usdc), address(safe), amount);
        liquidModule.deposit(address(safe), address(usdc), address(liquidVault), amount, amount, owner1, _depositSig(address(usdc), amount, amount));

        uint256 hfAfter = gw.healthFactor(address(safe));
        assertGt(hfAfter, hfBefore, "the deposit improved health");
        assertLt(hfAfter, 1.05e18, "while still under the floor, which no longer blocks it");
        assertEq(gw.suppliedOf(address(safe), address(liquidVault)), 10_100e6, "receipt supplied as collateral");
    }

    // The other half: from the same below-floor start, an operation that degrades health is still rejected.
    // Withdrawing escrows the receipt away with no resupply, so it strictly worsens the position.
    function test_withdraw_belowFloor_stillRejectedWhenHealthWorsens() public {
        _supplyToGateway(address(safe), address(liquidVault), 10_000e6);
        _borrowOnGateway(address(safe), address(usdc), 7800e6, recipient);
        vm.prank(owner);
        gw.setMinHealthFactor(1.05e18);
        assertLt(gw.healthFactor(address(safe)), 1.05e18, "safe starts below the floor");

        uint128 amount = 100e6;
        bytes memory sig = _withdrawSig(amount, amount, 0, 1 days);
        vm.expectRevert(LendGateway.HealthFactorBelowMinimum.selector);
        liquidModule.withdraw(address(safe), address(liquidVault), address(usdc), amount, amount, 0, 1 days, owner1, sig);
    }

    function _depositSig(address assetToDeposit, uint256 amount, uint256 minReturn) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(
            abi.encodePacked(liquidModule.DEPOSIT_SIG(), block.chainid, address(liquidModule), liquidModule.getNonce(address(safe)), address(safe), abi.encode(assetToDeposit, address(liquidVault), amount, minReturn))
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }

    function _withdrawSig(uint128 amount, uint128 minReturn, uint16 discount, uint24 secondsToDeadline) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(
            abi.encodePacked(liquidModule.WITHDRAW_SIG(), block.chainid, address(liquidModule), liquidModule.getNonce(address(safe)), address(safe), abi.encode(address(liquidVault), address(usdc), amount, minReturn, discount, secondsToDeadline))
        ).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }
}
