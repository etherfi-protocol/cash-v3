// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import { WithdrawalRequest } from "../../../../../src/interfaces/ICashModule.sol";
import { StargateModule } from "../../../../../src/modules/stargate/StargateModule.sol";
import { CashGatewayTestSetup } from "./CashGatewayTestSetup.t.sol";

/**
 * @title StargateGatewayTest
 * @notice Coverage-only: the Stargate module needs no Aave sandwich. requestBridge routes through
 *         cashModule.requestWithdrawalByModule, and the Cash withdrawal flow already sources a supplied
 *         balance out of Aave (CashLendLib.sourceWithdrawal) before the pending withdrawal is recorded. This
 *         proves a bridge request on a lend-active safe pulls the supplied asset back into the safe with no
 *         module-side change. Wormhole shares the same withdrawal-flow path and is covered by the same
 *         argument. No bridge is executed here (that needs the real Stargate endpoint); only the sourcing at
 *         request time is asserted.
 */
contract StargateGatewayTest is CashGatewayTestSetup {
    using MessageHashUtils for bytes32;

    StargateModule internal stargateModule;
    uint32 internal mainnetDestEid = 30_101;
    uint256 internal maxSlippage = 50;
    address internal destRecipientAddr = makeAddr("destRecipient");

    function setUp() public override {
        vm.skip(getChainConfig().stargateUsdcPool == address(0));
        super.setUp();

        address[] memory assets = _addr1(address(usdc));
        StargateModule.AssetConfig[] memory assetConfigs = new StargateModule.AssetConfig[](1);
        assetConfigs[0] = StargateModule.AssetConfig({ isOFT: false, pool: chainConfig.stargateUsdcPool });

        stargateModule = new StargateModule(assets, assetConfigs, address(dataProvider));
        _enableModule(address(stargateModule));

        // The bridge request creates a Cash withdrawal on the module's behalf, so it must be allowed to do so.
        vm.prank(owner);
        cashModule.configureModulesCanRequestWithdraw(_addr1(address(stargateModule)), _bool1(true));
    }

    // A bridge request on a lend-active safe whose USDC is supplied to Aave: the withdrawal flow sources the
    // supplied balance back into the safe, so the pending bridge withdrawal is covered without any sandwich.
    function test_requestBridge_sourcesSuppliedBalanceFromAave() public {
        uint256 amount = 100e6;
        _supplyToGateway(address(safe), address(usdc), amount);

        uint256 usdcSuppliedBefore = gw.suppliedOf(address(safe), address(usdc));
        assertEq(usdc.balanceOf(address(safe)), 0, "fixture: USDC supplied, none loose");

        (address[] memory signers, bytes[] memory signatures) = _getSignatures(mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage);
        stargateModule.requestBridge(address(safe), mainnetDestEid, address(usdc), amount, destRecipientAddr, maxSlippage, signers, signatures);

        // Sourced out of Aave into the safe, held loose to back the pending bridge withdrawal.
        assertEq(gw.suppliedOf(address(safe), address(usdc)), usdcSuppliedBefore - amount, "supplied USDC not sourced from Aave");
        assertEq(usdc.balanceOf(address(safe)), amount, "sourced USDC not held loose for the withdrawal");

        WithdrawalRequest memory request = cashModule.getData(address(safe)).pendingWithdrawalRequest;
        assertEq(request.tokens[0], address(usdc), "withdrawal asset mismatch");
        assertEq(request.amounts[0], amount, "withdrawal amount mismatch");
        assertEq(request.recipient, address(stargateModule), "withdrawal recipient must be the module");
    }

    function _getSignatures(uint32 destEid, address asset, uint256 amount, address destRecipient, uint256 maxSlippageInBps) internal view returns (address[] memory, bytes[] memory) {
        bytes32 digestHash = keccak256(abi.encodePacked(stargateModule.REQUEST_BRIDGE_SIG(), block.chainid, address(stargateModule), safe.nonce(), address(safe), abi.encode(destEid, asset, amount, destRecipient, maxSlippageInBps))).toEthSignedMessageHash();

        address[] memory signers = new address[](2);
        signers[0] = owner1;
        signers[1] = owner2;

        bytes[] memory signatures = new bytes[](2);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(owner1Pk, digestHash);
        signatures[0] = abi.encodePacked(r1, s1, v1);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(owner2Pk, digestHash);
        signatures[1] = abi.encodePacked(r2, s2, v2);

        return (signers, signatures);
    }
}
