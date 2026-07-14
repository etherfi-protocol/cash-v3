// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IFraxCustodian } from "../../../../../src/interfaces/IFraxCustodian.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { FraxModule } from "../../../../../src/modules/frax/FraxModule.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/// @dev Custodian stub: deposit pulls the 6-decimal asset and mints 18-decimal fraxUSD 1:1e12; redeem burns
///      fraxUSD and returns the asset (pre-funded in setUp). Enough to drive the sandwich without the real
///      Frax custodian's mint-cap / cross-chain mechanics.
contract MockFraxCustodian is IFraxCustodian {
    MockERC20 internal immutable fraxusd;
    IERC20 internal immutable asset;

    constructor(address _fraxusd, address _asset) {
        fraxusd = MockERC20(_fraxusd);
        asset = IERC20(_asset);
    }

    function deposit(uint256 amountIn, address receiver) external payable returns (uint256) {
        asset.transferFrom(receiver, address(this), amountIn);
        uint256 shares = amountIn * 1e12;
        fraxusd.mint(receiver, shares);
        return shares;
    }

    function redeem(uint256 sharesIn, address receiver, address owner) external returns (uint256) {
        fraxusd.transferFrom(owner, address(this), sharesIn);
        uint256 amountOut = sharesIn / 1e12;
        asset.transfer(receiver, amountOut);
        return amountOut;
    }
}

/**
 * @title FraxGatewayTest
 * @notice Exercises the Frax module's Aave sandwich against the real LendGateway: the synchronous deposit and
 *         withdraw source their input from Aave and re-supply the output as collateral. The custodian is a
 *         stub; the gateway and Aave are real. The async withdraw leg rides the Cash withdrawal flow (sourced
 *         elsewhere) and is not covered here.
 */
contract FraxGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    FraxModule internal fraxModule;
    MockFraxCustodian internal custodian;
    MockERC20 internal fraxusd;

    function setUp() public override {
        super.setUp();

        fraxusd = new MockERC20("Frax USD", "frxUSD", 18);

        // fraxUSD is a listed reserve so the deposit can re-supply it and the withdraw can pull it back ($1-priced).
        uint256 fraxReserveId = _addAaveReserve(address(fraxusd), usdcUsdOracle, 8000, false);

        custodian = new MockFraxCustodian(address(fraxusd), address(usdc));
        // Seed the custodian: fraxUSD to clear the module's synchronous-deposit balance check, USDC to pay redeems.
        fraxusd.mint(address(custodian), 1_000_000e18);
        deal(address(usdc), address(custodian), 1_000_000e6);

        fraxModule = new FraxModule(address(dataProvider), address(fraxusd), address(custodian), makeAddr("remoteHop"));
        _enableModule(address(fraxModule));

        vm.startPrank(owner);
        gw.setReserveId(address(fraxusd), fraxReserveId);
        // The sandwich drives gateway withdraw / supply on the safe's behalf, so it must be an authorized driver.
        gw.setDriver(address(fraxModule), true);
        vm.stopPrank();
    }

    // A deposit sources its USDC input from Aave and re-supplies the fraxUSD output as collateral.
    function test_deposit_sourcesUsdcFromAaveAndResuppliesFraxUsd() public {
        uint256 amount = 1000e6;
        _supplyToGateway(address(safe), address(usdc), amount);
        uint256 usdcSuppliedBefore = gw.suppliedOf(address(safe), address(usdc));

        uint256 minReturn = amount * 1e12;
        fraxModule.deposit(address(safe), address(usdc), amount, minReturn, owner1, _depositSig(address(usdc), amount, minReturn));

        assertEq(gw.suppliedOf(address(safe), address(usdc)), usdcSuppliedBefore - amount, "USDC not withdrawn from Aave");
        assertEq(gw.suppliedOf(address(safe), address(fraxusd)), minReturn, "fraxUSD output not re-supplied");
        assertEq(usdc.balanceOf(address(safe)), 0, "USDC left loose in safe");
        assertEq(fraxusd.balanceOf(address(safe)), 0, "fraxUSD output left loose in safe");
    }

    // A withdraw sources its fraxUSD input from Aave and re-supplies the USDC output as collateral.
    function test_withdraw_sourcesFraxUsdFromAaveAndResuppliesUsdc() public {
        uint128 shares = 1000e18;
        _supplyToGateway(address(safe), address(fraxusd), shares);
        uint256 usdcSuppliedBefore = gw.suppliedOf(address(safe), address(usdc));

        uint256 minReceive = uint256(shares) / 1e12;
        fraxModule.withdraw(address(safe), shares, address(usdc), minReceive, owner1, _withdrawSig(shares, address(usdc), minReceive));

        assertEq(gw.suppliedOf(address(safe), address(fraxusd)), 0, "fraxUSD not withdrawn from Aave");
        assertEq(gw.suppliedOf(address(safe), address(usdc)), usdcSuppliedBefore + minReceive, "USDC output not re-supplied");
        assertEq(fraxusd.balanceOf(address(safe)), 0, "fraxUSD left loose in safe");
        assertEq(usdc.balanceOf(address(safe)), 0, "USDC output left loose in safe");
    }

    // A legacy safe has not opted out yet must not touch Aave: the fraxUSD output stays loose.
    function test_deposit_legacySafe_outputStaysLoose() public {
        _forceLegacyEngine(address(safe));
        assertFalse(cashModule.isLendActive(address(safe)), "fixture: a legacy safe is not lend-active");

        uint256 amount = 1000e6;
        deal(address(usdc), address(safe), amount);

        uint256 minReturn = amount * 1e12;
        fraxModule.deposit(address(safe), address(usdc), amount, minReturn, owner1, _depositSig(address(usdc), amount, minReturn));

        assertEq(fraxusd.balanceOf(address(safe)), minReturn, "fraxUSD output must stay loose in the safe");
        assertEq(gw.suppliedOf(address(safe), address(fraxusd)), 0, "fraxUSD output must not be supplied to Aave");
    }

    function _depositSig(address asset, uint256 amount, uint256 minReturn) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(fraxModule.DEPOSIT_SIG(), block.chainid, address(fraxModule), fraxModule.getNonce(address(safe)), address(safe), abi.encode(asset, amount, minReturn))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }

    function _withdrawSig(uint128 amount, address outputAsset, uint256 minReceive) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(fraxModule.WITHDRAW_SIG(), block.chainid, address(fraxModule), fraxModule.getNonce(address(safe)), address(safe), abi.encode(amount, outputAsset, minReceive))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }
}
