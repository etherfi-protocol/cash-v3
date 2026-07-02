// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { Gateway } from "../../src/modules/gateway/Gateway.sol";
import { ChainlinkCompositePriceFeed } from "../../src/oracle/ChainlinkCompositePriceFeed.sol";
import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { CashModuleTestSetup } from "../safe/modules/cash/CashModuleTestSetup.t.sol";
import { AaveV4Fixture } from "./helpers/AaveV4Fixture.sol";

/**
 * @title GatewayHandler
 * @notice Drives random sequences of Gateway ops (as an authorized driver) for the invariant campaign.
 *         Amounts are bounded to mostly succeed so the campaign exercises real Aave state transitions;
 *         residual reverts (e.g. a withdraw that would breach health) are tolerated (fail_on_revert=false).
 * @dev Run with: source .env && FOUNDRY_PROFILE=aave TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/gateway/GatewayInvariant.t.sol"
 */
contract GatewayHandler is Test {
    Gateway internal immutable gw;
    address internal immutable safe;
    address internal immutable recipient;
    IERC20 internal immutable weeth;
    IERC20 internal immutable usdc;

    /// @notice Count of fully-successful gateway ops (guards against a hollow, all-reverting campaign)
    uint256 public opsExecuted;

    constructor(Gateway _gw, address _safe, address _recipient, IERC20 _weeth, IERC20 _usdc) {
        gw = _gw;
        safe = _safe;
        recipient = _recipient;
        weeth = _weeth;
        usdc = _usdc;
    }

    function supplyWeeth(uint256 amt) external {
        amt = bound(amt, 0.1 ether, 50 ether);
        deal(address(weeth), safe, weeth.balanceOf(safe) + amt);
        gw.supply(safe, address(weeth), amt);
        gw.setUsingAsCollateral(safe, address(weeth), true);
        opsExecuted++;
    }

    function borrowUsdc(uint256 amt) external {
        uint256 powerUsd = gw.getAccountData(safe).availableBorrowsUsd; // 6-decimal USD ~ USDC units
        if (powerUsd < 2e6) return;
        uint256 max = powerUsd > 5000e6 ? 5000e6 : powerUsd - 1e6;
        amt = bound(amt, 1e6, max);
        gw.borrow(safe, address(usdc), amt, recipient);
        opsExecuted++;
    }

    function repayUsdc(uint256 amt) external {
        uint256 debt = gw.debtOf(safe, address(usdc));
        if (debt == 0) return;
        amt = bound(amt, 1, debt + 50e6); // may exceed debt -> exercises the dust-refund path
        deal(address(usdc), safe, usdc.balanceOf(safe) + amt);
        gw.repay(safe, address(usdc), amt);
        opsExecuted++;
    }

    function withdrawWeeth(uint256 amt) external {
        uint256 supplied = gw.suppliedOf(safe, address(weeth));
        if (supplied == 0) return;
        amt = bound(amt, 1, supplied);
        gw.withdraw(safe, address(weeth), amt, recipient);
        opsExecuted++;
    }
}

/**
 * @title GatewayInvariantTest
 * @notice Invariant: after any sequence of gateway operations the gateway holds no tokens — its custody
 *         flow (pull-from-safe -> supply, withdraw/borrow -> forward, repay -> refund dust) must never
 *         strand user funds in the gateway. Runs against a real Aave v4 instance on an Optimism fork.
 */
contract GatewayInvariantTest is CashModuleTestSetup, AaveV4Fixture {
    Gateway internal gw;
    GatewayHandler internal handler;
    address internal recipient = makeAddr("invariantRecipient");
    uint256 internal usdcReserveId;
    uint256 internal weethReserveId;

    function setUp() public override {
        super.setUp();
        _deployAaveV4();

        address weethSource = address(new ChainlinkCompositePriceFeed(IAggregatorV3(weEthWethOracle), IAggregatorV3(ethUsdcOracle), 8, 30 days, 30 days, "weETH / USD"));
        weethReserveId = _addAaveReserve(address(weETH), weethSource, 80_00, false);
        usdcReserveId = _addAaveReserve(address(usdc), usdcUsdOracle, 80_00, true);
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);

        address gwImpl = address(new Gateway(address(dataProvider), address(spoke)));
        gw = Gateway(address(new UUPSProxy(gwImpl, abi.encodeWithSelector(Gateway.initialize.selector, address(roleRegistry)))));

        handler = new GatewayHandler(gw, address(safe), recipient, weETH, usdc);

        vm.startPrank(owner);
        roleRegistry.grantRole(gw.GATEWAY_ADMIN_ROLE(), owner);
        dataProvider.configureModules(_addr1(address(gw)), _bool1(true));
        gw.setReserveId(address(weETH), weethReserveId);
        gw.setReserveId(address(usdc), usdcReserveId);
        gw.setDriver(address(handler), true);
        vm.stopPrank();

        _enableModule(address(gw));
        _activateAavePositionManager(address(gw));

        // Only fuzz the handler's ops
        targetContract(address(handler));
    }

    /// @notice The gateway is a pure conduit: it must never hold token balances between operations.
    function invariant_gatewayHoldsNoStrandedFunds() external view {
        assertEq(weETH.balanceOf(address(gw)), 0, "no stranded weETH in gateway");
        assertEq(usdc.balanceOf(address(gw)), 0, "no stranded USDC in gateway");
    }

    /// @dev Ensures the campaign actually executed ops (not a hollow, all-reverting run)
    function afterInvariant() external view {
        assertGt(handler.opsExecuted(), 0, "handler executed real Aave ops");
    }

    function _enableModule(address module) internal {
        address[] memory modules = _addr1(module);
        bool[] memory shouldWhitelist = _bool1(true);
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";
        _configureModules(modules, shouldWhitelist, setupData);
    }

    function _addr1(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _bool1(bool b) internal pure returns (bool[] memory arr) {
        arr = new bool[](1);
        arr[0] = b;
    }
}
