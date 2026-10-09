// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { UUPSProxy } from "../../../../../src/UUPSProxy.sol";
import { AcrossSwapModule } from "../../../../../src/across/AcrossSwapModule.sol";
import { ModuleCheckBalance } from "../../../../../src/modules/ModuleCheckBalance.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/// @dev SpokePool stand-in that PULLS the deposit's input like the real one, so post-execute
///      balances mirror reality. Uses `fallback` because the legacy codegen can't generate the
///      dispatcher for the 12-arg `depositV3` signature; the input token and amount are sliced
///      straight out of calldata (args 2 and 4 after the 4-byte selector).
contract PullingSpokePoolStub {
    uint256 public callCount;
    address public hookTarget;
    bytes public hookData;

    /// @dev One-shot call made before the pull, standing in for a callback-capable route.
    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    fallback() external payable {
        if (hookTarget != address(0)) {
            address target = hookTarget;
            hookTarget = address(0);
            (bool ok, bytes memory reason) = target.call(hookData);
            if (!ok) assembly { revert(add(reason, 32), mload(reason)) }
        }
        address inputToken = address(uint160(uint256(bytes32(msg.data[68:100]))));
        uint256 inputAmount = uint256(bytes32(msg.data[132:164]));
        IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        callCount++;
    }

    receive() external payable { }
}

/**
 * @title AcrossSwapGatewayTest
 * @notice Exercises AcrossSwapModule's Aave sandwich against the real LendGateway: a gateway safe's
 *         input may be supplied to Aave, so the request-time sourcing (CashModule hold) and the
 *         module's execute-time front bookend must withdraw it back before the deposit. Every Across
 *         route bridges the output away, so there is no resupply half — the flow ends on the
 *         health-factor floor check. Runs on the Optimism fork under the lend profile.
 */
contract AcrossSwapGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    AcrossSwapModule internal swapModule;
    PullingSpokePoolStub internal spokePool;
    address internal multicallHandler = makeAddr("multicallHandler");
    address internal keeper = makeAddr("keeper");
    address internal tradingSafeFactory = makeAddr("tradingSafeFactory");
    address internal destinationRecipient;

    uint256 internal constant SRC_AMOUNT = 1_000e6;
    uint256 internal constant MIN_OUT = 990e6;
    bytes internal constant FAKE_MESSAGE = hex"cafebabe";

    function setUp() public override {
        super.setUp();

        destinationRecipient = CREATE3.predictDeterministicAddress(keccak256(abi.encode("TradingSafe", address(safe))), tradingSafeFactory);
        spokePool = new PullingSpokePoolStub();
        address impl = address(new AcrossSwapModule(address(dataProvider), tradingSafeFactory));
        swapModule = AcrossSwapModule(address(new UUPSProxy(
            impl,
            abi.encodeWithSelector(AcrossSwapModule.initialize.selector, address(roleRegistry), address(spokePool), multicallHandler)
        )));
        _enableModule(address(swapModule));

        vm.startPrank(owner);
        cashModule.configureModulesCanRequestWithdraw(_addr1(address(swapModule)), _bool1(true));
        // The sandwich drives gateway withdraw / supply on the safe's behalf, so it must be an authorized driver.
        gw.setDriver(address(swapModule), true);
        vm.stopPrank();
    }

    // The input sits supplied in Aave: request-time sourcing pulls it loose, and executeSwap forwards
    // it into the deposit. Nothing is left loose or supplied afterwards.
    function test_executeSwap_sourcesInputFromAave() public {
        _supplyToGateway(address(safe), address(usdc), SRC_AMOUNT);
        assertEq(usdc.balanceOf(address(safe)), 0, "fixture: input sits in Aave, not loose");

        _request(_baseOrder());

        // Request-time sourcing (CashModule hold) pulled the input out of Aave into the safe.
        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 0, 1, "input not pulled from Aave at request");
        assertEq(usdc.balanceOf(address(safe)), SRC_AMOUNT, "input not loose after request");

        _warpPastDelay();
        vm.prank(keeper);
        swapModule.executeSwap(address(safe));

        assertEq(spokePool.callCount(), 1, "deposit not dispatched");
        assertEq(usdc.balanceOf(address(safe)), 0, "input not consumed by the deposit");
    }

    // The execute-time front bookend: the input was loose at request (no pull), then got supplied into
    // Aave during the withdrawal delay. executeSwap must pull the shortfall back out to fund the deposit.
    function test_executeSwap_pullsShortfallSuppliedDuringDelay() public {
        deal(address(usdc), address(safe), SRC_AMOUNT);
        _request(_baseOrder());

        // Simulate the loose input landing in Aave during the delay window.
        vm.startPrank(driver);
        gw.supply(address(safe), address(usdc), SRC_AMOUNT);
        gw.setUsingAsCollateral(address(safe), address(usdc), true);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(safe)), 0, "fixture: input moved into Aave");

        _warpPastDelay();
        vm.prank(keeper);
        swapModule.executeSwap(address(safe));

        assertApproxEqAbs(gw.suppliedOf(address(safe), address(usdc)), 0, 2, "shortfall not pulled from Aave at execute");
        assertEq(usdc.balanceOf(address(safe)), 0, "input not consumed by the deposit");
        assertEq(spokePool.callCount(), 1, "deposit not dispatched");
    }

    // L-01: a callback during the deposit places a new hold on the input before the spoke pool pulls it.
    // The hold's request-time balance check passes, so only the post-call check can reject the under-backed hold.
    function test_executeSwap_revertsWhenCallbackHoldIsUnderBacked() public {
        deal(address(usdc), address(safe), SRC_AMOUNT);
        _request(_baseOrder());
        _warpPastDelay();

        spokePool.setHook(address(swapModule), _requestCalldata(_baseOrder()));

        vm.expectRevert(ModuleCheckBalance.PendingWithdrawalUnderBacked.selector);
        vm.prank(keeper);
        swapModule.executeSwap(address(safe));
    }

    // ---- Helpers ----

    function _baseOrder() internal returns (AcrossSwapModule.Order memory) {
        return AcrossSwapModule.Order({
            srcToken: address(usdc),
            srcAmount: SRC_AMOUNT,
            dstChainId: 1,
            dstToken: makeAddr("dstToken"),
            recipient: destinationRecipient,
            minOut: MIN_OUT,
            deadline: block.timestamp + 3 days
        });
    }

    function _baseDepositArgs() internal view returns (AcrossSwapModule.DepositArgs memory) {
        return AcrossSwapModule.DepositArgs({
            outputAmount: MIN_OUT,
            quoteTimestamp: uint32(block.timestamp),
            fillDeadline: uint32(block.timestamp + 30 minutes),
            exclusivityDeadline: 0,
            exclusiveRelayer: address(0)
        });
    }

    function _request(AcrossSwapModule.Order memory order) internal {
        (bool ok, bytes memory reason) = address(swapModule).call(_requestCalldata(order));
        if (!ok) assembly { revert(add(reason, 32), mload(reason)) }
    }

    function _requestCalldata(AcrossSwapModule.Order memory order) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(
            keccak256("AcrossSwapModule.requestSwap"),
            block.chainid,
            address(swapModule),
            safe.nonce(),
            address(safe),
            abi.encode(order),
            keccak256(abi.encode(_baseDepositArgs())),
            keccak256(FAKE_MESSAGE),
            keccak256(""),
            swapModule.getSpokePool(),
            swapModule.getMulticallHandler()
        )).toEthSignedMessageHash();
        (address[] memory signers, bytes[] memory sigs) = _twoSig(digest);
        return abi.encodeCall(
            AcrossSwapModule.requestSwap, (address(safe), order, _baseDepositArgs(), FAKE_MESSAGE, "", signers, sigs)
        );
    }

    function _twoSig(bytes32 digest) internal view returns (address[] memory, bytes[] memory) {
        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;
        bytes[] memory sigs = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digest);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digest);
        sigs[0] = abi.encodePacked(r1, s1, v1);
        sigs[1] = abi.encodePacked(r2, s2, v2);
        return (signers, sigs);
    }

    function _warpPastDelay() internal {
        (uint64 withdrawalDelay,,) = cashModule.getDelays();
        vm.warp(block.timestamp + withdrawalDelay + 1);
    }
}
