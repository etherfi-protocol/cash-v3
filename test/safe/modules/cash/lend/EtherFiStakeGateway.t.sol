// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { IL2SyncPool } from "../../../../../src/interfaces/IL2SyncPool.sol";
import { EtherFiStakeModule } from "../../../../../src/modules/etherfi/EtherFiStakeModule.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/// @dev Sync pool stub: returns weETH 1:1 to the staking safe (pre-funded with weETH in setUp), keeping the
///      ETH sent by the module. Enough to drive the sandwich without the real L2 staking mechanics.
contract MockSyncPool is IL2SyncPool {
    IERC20 internal immutable weETH;

    constructor(address _weETH) {
        weETH = IERC20(_weETH);
    }

    function deposit(address, uint256 amountIn, uint256) external payable returns (uint256) {
        weETH.transfer(msg.sender, amountIn);
        return amountIn;
    }

    receive() external payable { }
}

/**
 * @title EtherFiStakeGatewayTest
 * @notice Exercises the stake module's Aave sandwich against the real LendGateway: the WETH input is supplied
 *         to Aave, so the module withdraws it back, stakes through the (stubbed) sync pool, and re-supplies the
 *         weETH output as collateral. The sync pool is a stub; the gateway and Aave are real.
 */
contract EtherFiStakeGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    EtherFiStakeModule internal stakeModule;
    MockSyncPool internal syncPool;
    address internal weth;

    function setUp() public override {
        super.setUp();

        weth = chainConfig.weth;

        // WETH is a listed reserve so the sandwich can pull a supplied WETH input back out of Aave.
        uint256 wethReserveId = _addAaveReserve(weth, ethUsdcOracle, 8000, false);

        syncPool = new MockSyncPool(address(weETH));
        deal(address(weETH), address(syncPool), 100 ether);

        stakeModule = new EtherFiStakeModule(address(dataProvider), address(syncPool), weth, address(weETH));
        _enableModule(address(stakeModule));

        vm.startPrank(owner);
        gw.setReserveId(weth, wethReserveId);
        // The sandwich drives gateway withdraw / supply on the safe's behalf, so it must be an authorized driver.
        gw.setDriver(address(stakeModule), true);
        vm.stopPrank();
    }

    // A stake sources its WETH input entirely from Aave: the module withdraws the supplied WETH, stakes it, and
    // re-supplies the weETH output as collateral. Nothing is left loose in the safe.
    function test_deposit_sourcesWethFromAaveAndResuppliesWeETH() public {
        uint256 amount = 1 ether;
        _supplyToGateway(address(safe), weth, amount);

        uint256 wethSuppliedBefore = gw.suppliedOf(address(safe), weth);
        uint256 weethSuppliedBefore = gw.suppliedOf(address(safe), address(weETH));

        stakeModule.deposit(address(safe), weth, amount, amount, owner1, _depositSig(weth, amount, amount));

        assertEq(gw.suppliedOf(address(safe), weth), wethSuppliedBefore - amount, "WETH not withdrawn from Aave");
        assertEq(gw.suppliedOf(address(safe), address(weETH)), weethSuppliedBefore + amount, "weETH output not re-supplied");
        assertEq(IERC20(weth).balanceOf(address(safe)), 0, "WETH left loose in safe");
        assertEq(weETH.balanceOf(address(safe)), 0, "weETH output left loose in safe");
    }

    // The sandwich is engine-gated, not opt-out-gated: a legacy safe has not opted out, yet its stake must not
    // touch Aave — the weETH output stays loose where the DebtManager can see it.
    function test_deposit_legacySafe_outputStaysLoose() public {
        _forceLegacyEngine(address(safe));
        assertFalse(cashModule.isLendActive(address(safe)), "fixture: a legacy safe is not lend-active");

        uint256 amount = 1 ether;
        deal(weth, address(safe), amount);

        stakeModule.deposit(address(safe), weth, amount, amount, owner1, _depositSig(weth, amount, amount));

        assertEq(weETH.balanceOf(address(safe)), amount, "weETH output must stay loose in the safe");
        assertEq(gw.suppliedOf(address(safe), address(weETH)), 0, "weETH output must not be supplied to Aave");
    }

    function _depositSig(address assetToDeposit, uint256 amount, uint256 minReturn) internal view returns (bytes memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(stakeModule.DEPOSIT_SIG(), block.chainid, address(stakeModule), stakeModule.getNonce(address(safe)), address(safe), abi.encode(assetToDeposit, amount, minReturn))).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        return abi.encodePacked(r, s, v);
    }
}
