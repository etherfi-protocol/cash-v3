// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";

import { LendGateway } from "../../../../../src/modules/lend-gateway/LendGateway.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title LendGatewayHandler
 * @notice Drives random sequences of LendGateway ops (as an authorized driver) for the invariant campaign.
 *         Amounts are bounded to mostly succeed so the campaign exercises real Aave state transitions;
 *         residual reverts (e.g. a withdraw that would breach health) are tolerated (fail_on_revert=false).
 * @dev Run with: source .env && FOUNDRY_PROFILE=lend TEST_CHAIN=10 TEST_RPC="$OPTIMISM_RPC" forge test --match-path "test/safe/modules/cash/lend/LendGatewayInvariant.t.sol"
 */
contract LendGatewayHandler is Test {
    LendGateway internal immutable gw;
    address internal immutable safe;
    address internal immutable recipient;
    IERC20 internal immutable weeth;
    IERC20 internal immutable usdc;

    /// @notice Count of fully-successful gateway ops (guards against a hollow, all-reverting campaign)
    uint256 public opsExecuted;

    constructor(LendGateway _gw, address _safe, address _recipient, IERC20 _weeth, IERC20 _usdc) {
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
 * @title LendGatewayInvariantTest
 * @notice Invariant: after any sequence of gateway operations the gateway holds no tokens — its custody
 *         flow (pull-from-safe -> supply, withdraw/borrow -> forward, repay -> refund dust) must never
 *         strand user funds in the gateway. Runs against a real Aave v4 instance on an Optimism fork.
 */
contract LendGatewayInvariantTest is CashGatewayTestSetup {
    LendGatewayHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new LendGatewayHandler(gw, address(safe), recipient, weETH, usdc);
        vm.prank(owner);
        gw.setDriver(address(handler), true);

        // Only fuzz the handler's ops
        targetContract(address(handler));
    }

    /// @dev A larger seed so the campaign's bounded borrows are never capped by reserve liquidity.
    function _seedInitialLiquidity() internal override {
        _seedAaveLiquidity(usdcReserveId, address(usdc), 5_000_000e6);
    }

    /// @notice The gateway is a pure conduit: it must never hold token balances between operations.
    function invariant_gatewayHoldsNoStrandedFunds() external view {
        assertEq(weETH.balanceOf(address(gw)), 0, "no stranded weETH in gateway");
        assertEq(usdc.balanceOf(address(gw)), 0, "no stranded USDC in gateway");
    }

    /**
     * @notice Proves the handler can drive real Aave ops, so the invariant above is not passing vacuously
     *         over a hollow, all-reverting campaign.
     * @dev A plain test rather than afterInvariant: Foundry reverts the handler's state to the setUp snapshot
     *      before afterInvariant, so a ghost counter read there always sees zero.
     */
    function test_handlerDrivesRealOps() public {
        handler.supplyWeeth(5 ether);
        handler.borrowUsdc(100e6);
        assertEq(handler.opsExecuted(), 2, "handler executed a real supply and borrow");
    }
}
