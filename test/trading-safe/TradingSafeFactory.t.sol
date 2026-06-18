// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BeaconFactory } from "../../src/beacon-factory/BeaconFactory.sol";
import { ITradingLens } from "../../src/interfaces/ITradingLens.sol";
import { TradingSafe } from "../../src/trading-safe/TradingSafe.sol";
import { TradingSafeFactory } from "../../src/trading-safe/TradingSafeFactory.sol";
import { TradingSafeTestBase } from "./TradingSafeTestBase.t.sol";

contract TradingSafeFactoryTest is TradingSafeTestBase {
    TradingSafeFactory public factory;
    address public bridgeReceiver = makeAddr("bridgeReceiver");
    address public ownerA = makeAddr("ownerA");

    function setUp() public {
        _setupCore();

        vm.startPrank(owner);
        factory = _deployFactory(bridgeReceiver);
        _initDataProvider(address(factory));
        roleRegistry.grantRole(factory.TRADING_SAFE_FACTORY_ADMIN_ROLE(), owner);
        vm.stopPrank();
    }

    function _singleOwner() internal view returns (address[] memory tsOwners) {
        tsOwners = new address[](1);
        tsOwners[0] = ownerA;
    }

    // ---- Deterministic address ----

    function test_getDeterministicAddress_predictsDeploy() public {
        address sourceSafe = makeAddr("sourceSafe");
        address predicted = factory.getDeterministicAddress(sourceSafe);
        assertTrue(predicted != address(0));

        vm.startPrank(owner);
        TradingSafe deployed = _deployTradingSafe(factory, sourceSafe, _singleOwner(), 1);
        vm.stopPrank();

        assertEq(address(deployed), predicted, "deployed != predicted");
    }

    function test_getDeterministicAddress_differsAcrossSourceSafes() public {
        address a = factory.getDeterministicAddress(makeAddr("sourceA"));
        address b = factory.getDeterministicAddress(makeAddr("sourceB"));
        assertTrue(a != b);
    }

    // ---- Deploy gating ----

    function test_deployTradingSafe_revertsWhen_notAdmin() public {
        address sourceSafe = makeAddr("sourceSafe");
        address[] memory mods = new address[](0);
        bytes[] memory setupData = new bytes[](0);

        vm.expectRevert(TradingSafeFactory.OnlyAdmin.selector);
        factory.deployTradingSafe(sourceSafe, _singleOwner(), mods, setupData, 1);
    }

    function test_deployTradingSafe_succeedsForAdmin() public {
        address sourceSafe = makeAddr("sourceSafe");

        vm.startPrank(owner);
        TradingSafe deployed = _deployTradingSafe(factory, sourceSafe, _singleOwner(), 1);
        vm.stopPrank();

        assertTrue(address(deployed).code.length > 0, "no code at deployed address");
    }

    function test_deployTradingSafe_revertsWhen_sameSourceSafeTwice() public {
        address sourceSafe = makeAddr("sourceSafe");
        vm.startPrank(owner);
        _deployTradingSafe(factory, sourceSafe, _singleOwner(), 1);

        // Second deploy reuses the same salt -> CREATE3 collision. The factory bubbles up the
        // revert from solady's CREATE3 (no specific error message — just expectRevert).
        address[] memory mods = new address[](0);
        bytes[] memory setupData = new bytes[](0);
        vm.expectRevert();
        factory.deployTradingSafe(sourceSafe, _singleOwner(), mods, setupData, 1);
        vm.stopPrank();
    }

    // ---- Registration / pagination ----

    function test_isEtherFiSafe_falseBeforeDeploy_trueAfter() public {
        address sourceSafe = makeAddr("sourceSafe");
        address predicted = factory.getDeterministicAddress(sourceSafe);
        assertFalse(factory.isEtherFiSafe(predicted));

        vm.startPrank(owner);
        _deployTradingSafe(factory, sourceSafe, _singleOwner(), 1);
        vm.stopPrank();

        assertTrue(factory.isEtherFiSafe(predicted));
        assertFalse(factory.isEtherFiSafe(makeAddr("randomAddr")));
    }

    function test_dataProvider_isEtherFiSafe_delegatesToFactory() public {
        address sourceSafe = makeAddr("sourceSafe");
        vm.startPrank(owner);
        TradingSafe deployed = _deployTradingSafe(factory, sourceSafe, _singleOwner(), 1);
        vm.stopPrank();

        // Round-trip through the data provider — proves the factory satisfies the
        // IEtherFiSafeFactory selector.
        assertTrue(dataProvider.isEtherFiSafe(address(deployed)));
        assertFalse(dataProvider.isEtherFiSafe(makeAddr("randomAddr")));
    }

    function test_numContractsDeployed_increments() public {
        assertEq(factory.numContractsDeployed(), 0);

        vm.startPrank(owner);
        _deployTradingSafe(factory, makeAddr("s1"), _singleOwner(), 1);
        assertEq(factory.numContractsDeployed(), 1);

        _deployTradingSafe(factory, makeAddr("s2"), _singleOwner(), 1);
        assertEq(factory.numContractsDeployed(), 2);
        vm.stopPrank();
    }

    function test_getDeployedAddresses_returnsSlice() public {
        vm.startPrank(owner);
        address ts1 = address(_deployTradingSafe(factory, makeAddr("s1"), _singleOwner(), 1));
        address ts2 = address(_deployTradingSafe(factory, makeAddr("s2"), _singleOwner(), 1));
        address ts3 = address(_deployTradingSafe(factory, makeAddr("s3"), _singleOwner(), 1));
        vm.stopPrank();

        address[] memory all = factory.getDeployedAddresses(0, 10);
        assertEq(all.length, 3);
        assertEq(all[0], ts1);
        assertEq(all[1], ts2);
        assertEq(all[2], ts3);

        // Truncates when the requested window extends past the end.
        address[] memory tail = factory.getDeployedAddresses(1, 10);
        assertEq(tail.length, 2);
        assertEq(tail[0], ts2);
        assertEq(tail[1], ts3);
    }

    function test_getDeployedAddresses_revertsWhen_startOutOfRange() public {
        vm.expectRevert(TradingSafeFactory.InvalidStartIndex.selector);
        factory.getDeployedAddresses(0, 1);

        vm.startPrank(owner);
        _deployTradingSafe(factory, makeAddr("s1"), _singleOwner(), 1);
        vm.stopPrank();

        // start == length is also out of range.
        vm.expectRevert(TradingSafeFactory.InvalidStartIndex.selector);
        factory.getDeployedAddresses(1, 1);
    }

    // ---- input validation ----

    function test_deployTradingSafe_revertsOnZeroSourceSafe() public {
        address[] memory mods = new address[](0);
        bytes[] memory setupData = new bytes[](0);
        vm.prank(owner);
        vm.expectRevert(BeaconFactory.InvalidInput.selector);
        factory.deployTradingSafe(address(0), _singleOwner(), mods, setupData, 1);
    }

    function test_getTopUpAddress_revertsForUnknownSafe() public {
        vm.expectRevert(TradingSafeFactory.InvalidTradingSafe.selector);
        factory.getTopUpAddress(makeAddr("notASafe"));
    }

    // ---- setTradingLens / isSupportedToken ----

    function test_setTradingLens_revertsForNonOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        factory.setTradingLens(makeAddr("lens"));
    }

    function test_setTradingLens_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(TradingSafeFactory.TradingLensCannotBeZeroAddress.selector);
        factory.setTradingLens(address(0));
    }

    function test_setTradingLens_emitsEventAndUpdatesView() public {
        address lens = makeAddr("lens");
        vm.expectEmit(false, false, false, true, address(factory));
        emit TradingSafeFactory.TradingLensSet(address(0), lens);
        vm.prank(owner);
        factory.setTradingLens(lens);
        assertEq(factory.tradingLens(), lens);
    }

    function test_isSupportedToken_revertsWhenLensNotSet() public {
        vm.expectRevert(TradingSafeFactory.TradingLensNotSet.selector);
        factory.isSupportedToken(makeAddr("token"));
    }

    function test_isSupportedToken_delegatesToLens() public {
        address lens = makeAddr("lens");
        address token = makeAddr("token");
        vm.prank(owner);
        factory.setTradingLens(lens);

        vm.mockCall(lens, abi.encodeWithSelector(ITradingLens.isSupportedToken.selector, token), abi.encode(true));
        assertTrue(factory.isSupportedToken(token));

        vm.mockCall(lens, abi.encodeWithSelector(ITradingLens.isSupportedToken.selector, token), abi.encode(false));
        assertFalse(factory.isSupportedToken(token));
    }
}
