// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IL2BeHYPEOAppStaker } from "../../../../../src/interfaces/IL2BeHYPEOAppStaker.sol";
import { MockERC20 } from "../../../../../src/mocks/MockERC20.sol";
import { BeHYPEStakeModule } from "../../../../../src/modules/hype/BeHYPEStakeModule.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/// @dev Staker stub: pulls the WHYPE it is approved for and escrows it. beHYPE is delivered asynchronously on
///      the real staker, so the stub mints nothing back — matching the module having no re-supply bookend.
contract MockBeHYPEStaker is IL2BeHYPEOAppStaker {
    IERC20 internal immutable whype;

    constructor(address _whype) {
        whype = IERC20(_whype);
    }

    function quoteStake(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function stake(uint256 hypeAmountIn, address) external payable {
        whype.transferFrom(msg.sender, address(this), hypeAmountIn);
    }
}

/**
 * @title BeHYPEStakeGatewayTest
 * @notice Exercises the beHYPE stake module's Aave sandwich against the real LendGateway: the WHYPE input is
 *         supplied to Aave, so the module withdraws it back before staking. There is no re-supply bookend
 *         because beHYPE arrives asynchronously via LayerZero, not in the call. The staker is a stub; the
 *         gateway and Aave are real.
 */
contract BeHYPEStakeGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    BeHYPEStakeModule internal stakeModule;
    MockBeHYPEStaker internal staker;
    MockERC20 internal whype;
    MockERC20 internal beHYPE;

    function setUp() public override {
        super.setUp();

        whype = new MockERC20("Wrapped HYPE", "WHYPE", 18);
        beHYPE = new MockERC20("ether.fi HYPE", "beHYPE", 18);

        // WHYPE is a listed reserve so the sandwich can pull a supplied WHYPE input back out of Aave ($1-priced).
        uint256 whypeReserveId = _addAaveReserve(address(whype), usdcUsdOracle, 8000, false);

        staker = new MockBeHYPEStaker(address(whype));

        stakeModule = new BeHYPEStakeModule(address(dataProvider), address(staker), address(whype), address(beHYPE), 100_000);
        _enableModule(address(stakeModule));

        vm.startPrank(owner);
        gw.setReserveId(address(whype), whypeReserveId);
        // The sandwich drives gateway withdraw / supply on the safe's behalf, so it must be an authorized driver.
        gw.setDriver(address(stakeModule), true);
        vm.stopPrank();
    }

    // A stake sources its WHYPE input entirely from Aave: the module withdraws the supplied WHYPE and stakes it.
    // beHYPE is async, so nothing is re-supplied; the safe simply holds no loose WHYPE after.
    function test_stake_sourcesWhypeFromAave() public {
        uint256 amount = 100e18;
        _supplyToGateway(address(safe), address(whype), amount);
        uint256 whypeSuppliedBefore = gw.suppliedOf(address(safe), address(whype));

        stakeModule.stake(address(safe), amount, owner1, _stakeSig(amount));

        assertEq(gw.suppliedOf(address(safe), address(whype)), whypeSuppliedBefore - amount, "WHYPE not withdrawn from Aave");
        assertEq(whype.balanceOf(address(safe)), 0, "WHYPE left loose in safe");
        assertEq(whype.balanceOf(address(staker)), amount, "WHYPE not staked");
    }

    // A legacy safe has not opted out yet must not touch Aave: its loose WHYPE is staked directly.
    function test_stake_legacySafe_doesNotTouchAave() public {
        _forceLegacyEngine(address(safe));
        assertFalse(cashModule.isLendActive(address(safe)), "fixture: a legacy safe is not lend-active");

        uint256 amount = 100e18;
        deal(address(whype), address(safe), amount);

        stakeModule.stake(address(safe), amount, owner1, _stakeSig(amount));

        assertEq(gw.suppliedOf(address(safe), address(whype)), 0, "must not touch Aave for a legacy safe");
        assertEq(whype.balanceOf(address(staker)), amount, "WHYPE not staked");
    }

    function _stakeSig(uint256 amount) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(stakeModule.STAKE_SIG(), block.chainid, address(stakeModule), stakeModule.getNonce(address(safe)), address(safe), abi.encode(amount))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }
}
