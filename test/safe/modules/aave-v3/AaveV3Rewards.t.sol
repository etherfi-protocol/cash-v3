// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AaveV3TestSetup, MessageHashUtils, AaveV3Module, ModuleBase, IDebtManager, IERC20 } from "./AaveV3TestSetup.t.sol";
import { EtherFiSafeErrors } from "../../../../src/safe/EtherFiSafeErrors.sol";
import { IAavePoolV3 } from "../../../../src/interfaces/IAavePoolV3.sol";
import { IAaveV3IncentivesManager } from "../../../../src/interfaces/IAaveV3IncentivesManager.sol";

contract AaveV3RewardsTest is AaveV3TestSetup {
    using MessageHashUtils for bytes32;

    address rewardToken;
    address[] reserveAssets;

    function setUp() public override {
        super.setUp();

        // Supply ETH and borrow USDC for generating rewards
        uint256 collateralAmount = 10 ether;
        deal(address(safe), collateralAmount);

        bytes32 supplyDigestHash = keccak256(abi.encodePacked(
            aaveV3Module.SUPPLY_SIG(), 
            block.chainid, 
            address(aaveV3Module), 
            aaveV3Module.getNonce(address(safe)), 
            address(safe), 
            abi.encode(ETH, collateralAmount)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, supplyDigestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        aaveV3Module.supply(address(safe), ETH, collateralAmount, owner1, signature);

        // Setup for aToken asset array
        reserveAssets = new address[](1);
        IAavePoolV3.ReserveDataLegacy memory reserveData = aaveV3Module.aaveV3Pool().getReserveData(ETH);
        reserveAssets[0] = reserveData.aTokenAddress;

        // Mock reward token (could be any token in real scenario)
        rewardToken = address(0x1234567890123456789012345678901234567890);
    }

    function test_claimRewards_claimsSpecificRewardAmount() public {
        uint256 rewardAmount = 1e18;
        
        // Mock the reward claim operation with an expectation
        vm.mockCall(
            address(aaveV3Module.aaveIncentivesManager()),
            abi.encodeWithSelector(
                IAaveV3IncentivesManager.claimRewardsToSelf.selector, 
                reserveAssets,
                rewardAmount,
                rewardToken
            ),
            ""
        );

        vm.expectEmit(true, true, true, true);
        emit AaveV3Module.ClaimRewardsOnAave(address(safe), reserveAssets, rewardAmount, rewardToken);
        
        aaveV3Module.claimRewards(address(safe), reserveAssets, rewardAmount, rewardToken);
    }

    function test_claimRewards_reverts_whenCallerIsNotEtherFiSafe() public {
        uint256 rewardAmount = 1e18;
        address notASafe = address(0x9999);
        
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        aaveV3Module.claimRewards(notASafe, reserveAssets, rewardAmount, rewardToken);
    }

    function test_claimRewards_reverts_whenUserCashPositionNotHealthy() public {
        uint256 rewardAmount = 1e18;
        
        vm.mockCallRevert(
            address(debtManager), 
            abi.encodeWithSelector(IDebtManager.ensureHealth.selector, address(safe)), 
            abi.encodeWithSelector(IDebtManager.AccountUnhealthy.selector)
        );
        
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.CallFailed.selector, 0));
        aaveV3Module.claimRewards(address(safe), reserveAssets, rewardAmount, rewardToken);
    }

    function test_claimAllRewards_claimsAllRewards() public {
        vm.mockCall(
            address(aaveV3Module.aaveIncentivesManager()),
            abi.encodeWithSelector(
                IAaveV3IncentivesManager.claimAllRewardsToSelf.selector, 
                reserveAssets
            ),
            ""
        );

        vm.expectEmit(true, true, true, true);
        emit AaveV3Module.ClaimAllRewardsOnAave(address(safe), reserveAssets);
        
        aaveV3Module.claimAllRewards(address(safe), reserveAssets);
    }

    function test_claimAllRewards_reverts_whenCallerIsNotEtherFiSafe() public {
        address notASafe = address(0x9999);
        
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        aaveV3Module.claimAllRewards(notASafe, reserveAssets);
    }

    function test_claimAllRewards_reverts_whenUserCashPositionNotHealthy() public {
        vm.mockCallRevert(
            address(debtManager), 
            abi.encodeWithSelector(IDebtManager.ensureHealth.selector, address(safe)), 
            abi.encodeWithSelector(IDebtManager.AccountUnhealthy.selector)
        );
        
        vm.expectRevert(abi.encodeWithSelector(EtherFiSafeErrors.CallFailed.selector, 0));
        aaveV3Module.claimAllRewards(address(safe), reserveAssets);
    }

    function test_claimRewards_handlesMultipleAssets() public {
        uint256 rewardAmount = 1e18;
        
        address[] memory multiAssets = new address[](3);
        multiAssets[0] = reserveAssets[0];
        multiAssets[1] = address(0x2222);
        multiAssets[2] = address(0x3333);
        
        vm.mockCall(
            address(aaveV3Module.aaveIncentivesManager()),
            abi.encodeWithSelector(
                IAaveV3IncentivesManager.claimRewardsToSelf.selector, 
                multiAssets,
                rewardAmount,
                rewardToken
            ),
            ""
        );

        vm.expectEmit(true, true, true, true);
        emit AaveV3Module.ClaimRewardsOnAave(address(safe), multiAssets, rewardAmount, rewardToken);
        
        aaveV3Module.claimRewards(address(safe), multiAssets, rewardAmount, rewardToken);
    }
}