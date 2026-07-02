// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { UUPSProxy } from "../../../../src/UUPSProxy.sol";
import { ICashModule, Mode, SafeCashData } from "../../../../src/interfaces/ICashModule.sol";
import { IGateway } from "../../../../src/interfaces/IGateway.sol";
import { CashVerificationLib } from "../../../../src/libraries/CashVerificationLib.sol";
import { MockGateway } from "../../../../src/mocks/MockGateway.sol";
import { CashLens } from "../../../../src/modules/cash/CashLens.sol";
import { CashModuleCore } from "../../../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../../../src/modules/cash/CashModuleSetters.sol";
import { CashEventEmitter, CashModuleTestSetup } from "./CashModuleTestSetup.t.sol";

contract CashModuleSetGatewayTest is CashModuleTestSetup {
    using MessageHashUtils for bytes32;

    /// @notice A controller can configure the first gateway during Lend bootstrap and the change is emitted.
    function test_setGateway_emitsAndUpdates() public {
        (ICashModule unconfiguredCashModule,) = _deployUnconfiguredCashModule();
        MockGateway newGateway = new MockGateway();

        vm.expectEmit(true, true, true, true);
        emit CashEventEmitter.GatewayUpdated(address(0), address(newGateway));

        vm.prank(owner);
        unconfiguredCashModule.setGateway(address(newGateway));

        assertEq(address(unconfiguredCashModule.getGateway()), address(newGateway));
    }

    /// @notice CashLens should read the gateway configured during the one-time Lend bootstrap.
    function test_setGateway_bootstrapUpdatesCashLensReads() public {
        (ICashModule unconfiguredCashModule, CashLens unconfiguredCashLens) = _deployUnconfiguredCashModule();
        MockGateway newGateway = new MockGateway();

        vm.prank(address(safe));
        unconfiguredCashModule.setupModule(abi.encode(dailyLimitInUsd, monthlyLimitInUsd, timezoneOffset));
        _setMode(unconfiguredCashModule, Mode.Credit);
        vm.warp(unconfiguredCashModule.incomingModeStartTime(address(safe)) + 1);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory amountsInUsd = new uint256[](1);
        amountsInUsd[0] = 100e6;

        newGateway.setAvailableCash(address(usdc), type(uint128).max);
        newGateway.setAccountData(address(safe), IGateway.AccountData({ collateralUsd: 200e6, debtUsd: 0, availableBorrowsUsd: amountsInUsd[0], healthFactor: type(uint256).max }));

        vm.prank(owner);
        unconfiguredCashModule.setGateway(address(newGateway));

        assertEq(address(unconfiguredCashLens.gateway()), address(newGateway));

        SafeCashData memory data = unconfiguredCashLens.getSafeCashData(address(safe), tokens);
        assertEq(data.totalCollateral, 200e6);
        assertEq(data.creditMaxSpend, amountsInUsd[0]);

        (bool canSpendAfter, string memory reason) = unconfiguredCashLens.canSpend(address(safe), txId, tokens, amountsInUsd);
        assertEq(canSpendAfter, true);
        assertEq(reason, "");
    }

    /// @notice Gateway bootstrap rejects unauthorized callers, zero addresses, and attempts to overwrite a configured gateway.
    function test_setGateway_revertsForInvalidCalls() public {
        MockGateway newGateway = new MockGateway();

        vm.prank(notOwner);
        vm.expectRevert(ICashModule.OnlyCashModuleController.selector);
        cashModule.setGateway(address(newGateway));

        vm.prank(owner);
        vm.expectRevert(ICashModule.InvalidInput.selector);
        cashModule.setGateway(address(0));

        vm.prank(owner);
        vm.expectRevert(ICashModule.GatewayAlreadySet.selector);
        cashModule.setGateway(address(newGateway));
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
