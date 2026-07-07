// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { IAggregatorV3 } from "../../../../../src/interfaces/IAggregatorV3.sol";
import { LendGateway } from "../../../../../src/modules/lend-gateway/LendGateway.sol";
import { ChainlinkCompositePriceFeed } from "../../../../../src/oracle/ChainlinkCompositePriceFeed.sol";
import { AaveV4Fixture } from "../../../../lend-gateway/helpers/AaveV4Fixture.sol";
import { CashModuleTestSetup } from "../CashModuleTestSetup.t.sol";

/**
 * @title CashGatewayTestSetup
 * @notice Shared setup for cash-flow tests that exercise the REAL LendGateway backed by a real Aave v4
 *         instance deployed in-test on an Optimism fork, with the gateway wired into the CashModule as the
 *         live lend engine. Positions are built through real supply / borrow flows, never injected via mock
 *         setters, so gateway-path behavior (borrowing power, declines, rounding, atomicity) is asserted
 *         against genuine Aave state.
 * @dev These tests run only under the aave profile (the default profile skips test/safe/modules/cash/aave/**,
 *      since a real Aave v4 build needs via_ir). Run with:
 *      source .env && FOUNDRY_PROFILE=aave TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/aave/**"
 */
abstract contract CashGatewayTestSetup is CashModuleTestSetup, AaveV4Fixture {
    LendGateway internal gw;
    address internal driver = makeAddr("gwDriver"); // arranges Aave positions directly in tests
    address internal recipient = makeAddr("gwRecipient");

    uint256 internal usdcReserveId;
    uint256 internal weethReserveId;

    function setUp() public virtual override {
        // Real ether.fi stack on an Optimism fork (the mock gateway wiring is skipped via _wireDefaultGateway)
        super.setUp();

        // Real Aave v4 instance on the fork, weETH + USDC reserves priced by live Chainlink feeds
        _deployAaveV4();
        address weethSource = address(new ChainlinkCompositePriceFeed(IAggregatorV3(weEthWethOracle), IAggregatorV3(ethUsdcOracle), 8, 30 days, 30 days, "weETH / USD"));
        weethReserveId = _addAaveReserve(address(weETH), weethSource, _weethCollateralFactorBps(), false);
        usdcReserveId = _addAaveReserve(address(usdc), usdcUsdOracle, _usdcCollateralFactorBps(), true);
        _seedInitialLiquidity();

        // LendGateway proxy pointing at the fresh spoke, wired as the CashModule's live lend engine
        address gwImpl = address(new LendGateway(address(dataProvider), address(spoke)));
        gw = LendGateway(address(new UUPSProxy(gwImpl, abi.encodeWithSelector(LendGateway.initialize.selector, address(roleRegistry)))));

        vm.startPrank(owner);
        roleRegistry.grantRole(gw.LEND_GATEWAY_ADMIN_ROLE(), owner);
        dataProvider.configureModules(_addr1(address(gw)), _bool1(true));
        gw.setReserveId(address(weETH), weethReserveId);
        gw.setReserveId(address(usdc), usdcReserveId);
        gw.setDriver(driver, true);
        cashModule.setLendGateway(address(gw));
        vm.stopPrank();

        _enableModule(address(gw));
        _activateAavePositionManager(address(gw));
    }

    /// @dev Empty on purpose: skips the base mock-gateway wiring so this suite's one-time setLendGateway(gw) is the first and only set.
    function _wireDefaultGateway() internal override { }

    // ----------------------------------------------------------------- overridable reserve policy

    /// @dev weETH reserve collateral factor in BPS; override to model a different Aave LTV.
    function _weethCollateralFactorBps() internal pure virtual returns (uint16) {
        return 8000;
    }

    /// @dev USDC reserve collateral factor in BPS; override to model a different Aave LTV.
    function _usdcCollateralFactorBps() internal pure virtual returns (uint16) {
        return 8000;
    }

    /// @dev Borrowable liquidity seeded into the USDC reserve at setup; override to seed a different amount (or none).
    function _seedInitialLiquidity() internal virtual {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 1_000_000e6);
    }

    // ----------------------------------------------------------------- module wiring helpers

    /// @dev Whitelists (via dataProvider) then enables `module` on the safe via owner signatures.
    function _enableModule(address module) internal {
        address[] memory modules = _addr1(module);
        bool[] memory shouldWhitelist = _bool1(true);
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";
        _configureModules(modules, shouldWhitelist, setupData);
    }

    function _addr1(address a) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = a;
        return arr;
    }

    function _bool1(bool b) internal pure returns (bool[] memory) {
        bool[] memory arr = new bool[](1);
        arr[0] = b;
        return arr;
    }
}
