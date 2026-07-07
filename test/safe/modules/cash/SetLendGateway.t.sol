// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { BinSponsor, ICashModule, Mode, SafeCashData } from "../../../../src/interfaces/ICashModule.sol";
import { ILendGateway } from "../../../../src/interfaces/ILendGateway.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { MockLendGateway } from "../../../../src/mocks/MockLendGateway.sol";
import { CashLens } from "../../../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../../../src/modules/cash/CashModuleSetters.sol";
import { CashEventEmitter, CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

contract CashModuleSetLendGatewayTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    /// @notice New safes onboard onto the Aave gateway engine; a debt-free re-setup also flips to the gateway.
    function test_setupModule_flagsNewSafeAsAaveGateway() public {
        assertTrue(cashModule.usesLendGateway(address(safe)), "new safe defaults to the gateway engine");

        _forceLegacyEngine(address(safe));

        vm.prank(address(safe));
        cashModule.setupModule(abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset));
        assertTrue(cashModule.usesLendGateway(address(safe)), "debt-free re-setup flips to the gateway");
    }

    /// @notice A legacy safe with open DebtManager debt must keep routing to DebtManager if setup re-runs;
    ///         flipping it without migrating would strand the legacy debt behind gateway routing.
    function test_setupModule_keepsLegacySafeWithDebtOnLegacyEngine() public {
        _forceLegacyEngine(address(safe));

        deal(address(weETH), address(safe), 10 ether);
        deal(address(usdc), address(debtManager), 1_000_000e6);
        vm.prank(address(safe));
        debtManager.borrow(BinSponsor.Reap, address(usdc), 10e6);

        vm.prank(address(safe));
        cashModule.setupModule(abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset));
        assertFalse(cashModule.usesLendGateway(address(safe)), "safe with legacy debt stays on the legacy engine");
    }

    /// @notice A controller can configure the first gateway during Lend bootstrap and the change is emitted.
    function test_setLendGateway_emitsAndUpdates() public {
        (ICashModule unconfiguredCashModule,) = _deployUnconfiguredCashModule();
        MockLendGateway newGateway = new MockLendGateway();

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.LendGatewaySet(address(newGateway));

        vm.prank(owner);
        unconfiguredCashModule.setLendGateway(address(newGateway));

        assertEq(address(unconfiguredCashModule.getLendGateway()), address(newGateway));
    }

    /// @notice CashLens should read the gateway configured during the one-time Lend bootstrap.
    function test_setLendGateway_bootstrapUpdatesCashLensReads() public {
        (ICashModule unconfiguredCashModule, CashLens unconfiguredCashLens) = _deployUnconfiguredCashModule();
        MockLendGateway newGateway = new MockLendGateway();

        vm.prank(address(safe));
        unconfiguredCashModule.setupModule(abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset));
        _setMode(unconfiguredCashModule, Mode.Credit);
        vm.warp(unconfiguredCashModule.incomingModeStartTime(address(safe)) + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = 100e6;

        newGateway.setAvailableCash(address(usdc), type(uint128).max);
        newGateway.setAccountData(address(safe), ILendGateway.AccountData({ collateralUsd: 200e6, debtUsd: 0, availableBorrowsUsd: amountsInUsd[0], healthFactor: type(uint256).max }));

        vm.prank(owner);
        unconfiguredCashModule.setLendGateway(address(newGateway));

        assertEq(address(unconfiguredCashLens.gateway()), address(newGateway));

        SafeCashData memory data = unconfiguredCashLens.getSafeCashData(address(safe), tokens);
        assertEq(data.totalCollateral, 200e6);
        assertEq(data.creditMaxSpend, amountsInUsd[0]);

        (bool canSpendAfter, string memory reason) = unconfiguredCashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        assertEq(canSpendAfter, true);
        assertEq(reason, "");
    }

    /// @notice LendGateway bootstrap rejects unauthorized callers, zero addresses, and attempts to overwrite a configured gateway.
    function test_setLendGateway_revertsForInvalidCalls() public {
        MockLendGateway newGateway = new MockLendGateway();

        vm.prank(notOwner);
        vm.expectRevert(ICashModule.OnlyCashModuleController.selector);
        cashModule.setLendGateway(address(newGateway));

        vm.prank(owner);
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.setLendGateway(address(0));

        // An address with no contract code is rejected by the deployed-contract check.
        vm.prank(owner);
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.setLendGateway(makeAddr("codelessGateway"));

        vm.prank(owner);
        vm.expectRevert(ICashModule.GatewayAlreadySet.selector);
        cashModule.setLendGateway(address(newGateway));
    }

    /// @dev Deploys a CashModule/CashLens pair with no gateway configured so tests can exercise first-time bootstrap.
    function _deployUnconfiguredCashModule() internal returns (ICashModule unconfiguredCashModule, CashLens unconfiguredCashLens) {
        address cashModuleSettersImpl = address(new CashModuleSetters(address(dataProvider)));
        address cashModuleCoreImpl = address(new CashModuleCore(address(dataProvider)));
        unconfiguredCashModule = ICashModule(address(new UUPSProxy(cashModuleCoreImpl, "")));
        address cashEventEmitterImpl = address(new CashEventEmitter(address(unconfiguredCashModule)));
        address unconfiguredCashEventEmitter = address(new UUPSProxy(cashEventEmitterImpl, abi.encodeWithSelector(CashEventEmitter.initialize.selector, address(roleRegistry))));

        CashModuleCore(address(unconfiguredCashModule)).initialize(address(roleRegistry), address(debtManager), address(settlementDispatcherReap), address(settlementDispatcherRain), address(cashbackDispatcher), unconfiguredCashEventEmitter, cashModuleSettersImpl);

        address cashLensImpl = address(new CashLens(address(unconfiguredCashModule), address(dataProvider)));
        unconfiguredCashLens = CashLens(address(new UUPSProxy(cashLensImpl, abi.encodeWithSelector(CashLens.initialize.selector, address(roleRegistry)))));
    }

    /// @dev Sets mode on a specific CashModule instance using the shared Safe owner key.
    function _setMode(ICashModule module, Mode mode) internal {
        uint256 nonce = module.getNonce(address(safe));
        bytes32 digestHash = keccak256(abi.encodePacked(CashVerificationLib.SET_MODE_METHOD, block.chainid, address(safe), nonce, abi.encode(mode))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);

        module.setMode(address(safe), mode, owner1, abi.encodePacked(r, s, v));
    }
}
