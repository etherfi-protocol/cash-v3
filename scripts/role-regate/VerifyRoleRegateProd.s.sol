// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { CashModuleCore } from "../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../src/modules/cash/CashModuleSetters.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { TradingSafeLiquidDepositModule } from "../../src/trading-safe/TradingSafeLiquidDepositModule.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";
import { RoleRegateProdConfig } from "./RoleRegateProdConfig.sol";

/**
 * @title VerifyRoleRegateProd
 * @notice Verifies the contracts DeployRoleRegateProd.s.sol deployed for cash-v3 #356 against this source tree. Each
 *         address must be the CREATE3 address of its salt, and its runtime bytecode must match a local build with the
 *         same constructor args. Rollout status (proxies on the new impls, new modules enabled) is only logged, so
 *         this works before and after the 3CP executes.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/role-regate/VerifyRoleRegateProd.s.sol --rpc-url $OPTIMISM_RPC -vv \
 *     --libraries src/modules/lend-gateway/LendReserveLib.sol:LendReserveLib:0xd65eCb4E22D578Bc732d51AAa4F0449D225fd723
 *   ENV=mainnet forge script scripts/role-regate/VerifyRoleRegateProd.s.sol --rpc-url $MAINNET_RPC -vv
 *
 * @dev UUPS implementations embed their own address, so they use the address-binding comparison, which also verifies
 *      LendGateway's linked LendReserveLib recursively. The modules are not upgradeable and use exact comparison.
 */
contract VerifyRoleRegateProd is EtherFiDeployerHelper, ContractCodeChecker, RoleRegateProdConfig {
    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "ENV must be mainnet");
        if (block.chainid == 10) _verifyOptimism();
        else if (block.chainid == 1) _verifyEthereum();
        else revert("run on Optimism or Ethereum");
        console2.log("Role re-gate bytecode verification passed");
    }

    function _verifyOptimism() internal {
        require(_predictAddress(LIB_SALT) == LEND_RESERVE_LIB, "unexpected LendReserveLib address");
        require(_predictAddress(OP_DP_IMPL_SALT) == OP_DP_IMPL, "unexpected EtherFiDataProvider impl address");
        require(_predictAddress(SETTERS_SALT) == NEW_SETTERS, "unexpected CashModuleSetters address");
        require(_predictAddress(GW_IMPL_SALT) == NEW_GW_IMPL, "unexpected LendGateway impl address");
        require(_predictAddress(LIQUIFIER_IMPL_SALT) == NEW_LIQUIFIER_IMPL, "unexpected LiquidUSDLiquifierOP impl address");
        require(_predictAddress(FRAX_SALT) == NEW_FRAX, "unexpected FraxModule address");
        require(_predictAddress(MIDAS_SALT) == NEW_MIDAS, "unexpected MidasModule address");

        require(_codeContainsAddress(NEW_GW_IMPL, LEND_RESERVE_LIB), "LendGateway impl is not linked to the pinned LendReserveLib");
        requireCodeMatchAllowingAddressEmbeds("EtherFiDataProviderImpl", OP_DP_IMPL, address(new EtherFiDataProvider()));
        requireCodeMatchAllowingAddressEmbeds("CashModuleSetters", NEW_SETTERS, address(new CashModuleSetters(OP_DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("LendGatewayImpl", NEW_GW_IMPL, address(new LendGateway(OP_DATA_PROVIDER, AAVE_SPOKE)));
        requireCodeMatchAllowingAddressEmbeds("LiquidUSDLiquifierOPImpl", NEW_LIQUIFIER_IMPL, address(new LiquidUSDLiquifierOPModule(DEBT_MANAGER, OP_DATA_PROVIDER)));
        requireExactCodeMatch("FraxModule", NEW_FRAX, address(new FraxModule(OP_DATA_PROVIDER, FRAXUSD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP)));
        (address[] memory tokens, address[] memory deposits, address[] memory redemptions) = _midasArgs();
        requireExactCodeMatch("MidasModule", NEW_MIDAS, address(new MidasModule(OP_DATA_PROVIDER, tokens, deposits, redemptions)));

        console2.log("  rollout: data provider on the new impl:", _impl(OP_DATA_PROVIDER) == OP_DP_IMPL);
        console2.log("  rollout: CashModule on the new setters:", CashModuleCore(CASH_MODULE).getCashModuleSetters() == NEW_SETTERS);
        console2.log("  rollout: lend gateway on the new impl:", _impl(OP_LEND_GATEWAY) == NEW_GW_IMPL);
        console2.log("  rollout: liquifier on the new impl:", _impl(OP_LIQUIFIER) == NEW_LIQUIFIER_IMPL);
        console2.log("  rollout: new Frax is a default module:", EtherFiDataProvider(OP_DATA_PROVIDER).isDefaultModule(NEW_FRAX));
        console2.log("  rollout: new Midas is a default module:", EtherFiDataProvider(OP_DATA_PROVIDER).isDefaultModule(NEW_MIDAS));
    }

    function _verifyEthereum() internal {
        require(_predictAddress(ETH_DP_IMPL_SALT) == ETH_DP_IMPL, "unexpected trading EtherFiDataProvider impl address");
        require(_predictAddress(DEPOSIT_SALT) == NEW_DEPOSIT_MODULE, "unexpected TradingSafeLiquidDepositModule address");
        requireCodeMatchAllowingAddressEmbeds("TradingEtherFiDataProviderImpl", ETH_DP_IMPL, address(new EtherFiDataProvider()));
        (address[] memory assets, address[] memory tellers) = _depositArgs();
        requireExactCodeMatch("TradingSafeLiquidDepositModule", NEW_DEPOSIT_MODULE, address(new TradingSafeLiquidDepositModule(assets, tellers, ETH_DATA_PROVIDER)));

        console2.log("  rollout: trading data provider on the new impl:", _impl(ETH_DATA_PROVIDER) == ETH_DP_IMPL);
        console2.log("  rollout: new deposit module is a default module:", EtherFiDataProvider(ETH_DATA_PROVIDER).isDefaultModule(NEW_DEPOSIT_MODULE));
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPL_SLOT))));
    }
}
