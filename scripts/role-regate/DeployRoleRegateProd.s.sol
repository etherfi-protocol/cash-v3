// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
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
 * @title DeployRoleRegateProd
 * @notice CREATE3-deploys the prod contracts for cash-v3 #356 (COR-1794 re-gating, COR-1792 invariants, and the
 *         Certora Item 27 fixes) through the on-chain EtherFiDeployer. Deploying changes no live state: the proxies
 *         are upgraded and the new modules enabled by the 3CP bundles from RoleRegateProd3CP.s.sol.
 *           Optimism (10): LendReserveLib, and the EtherFiDataProvider, CashModuleSetters, LendGateway and
 *                          LiquidUSDLiquifierOP implementations; new FraxModule and MidasModule instances built with
 *                          the live modules' constructor args
 *           Ethereum (1):  the trading EtherFiDataProvider implementation; a new TradingSafeLiquidDepositModule
 *                          built with the live module's constructor args
 *         Idempotent: an address that already holds code is not redeployed.
 *
 * @dev LendGateway calls the external library LendReserveLib, so its bytecode embeds the library's address. The
 *      library is CREATE3-deployed at a pinned address, and the LendGateway build must be linked to that address
 *      with --libraries on the Optimism run (the script checks the impl embeds it). Without the flag forge would
 *      link a throwaway library address and the check fails before anything is broadcast.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/role-regate/DeployRoleRegateProd.s.sol --rpc-url $OPTIMISM_RPC --broadcast --verify \
 *     --libraries src/modules/lend-gateway/LendReserveLib.sol:LendReserveLib:0xd65eCb4E22D578Bc732d51AAa4F0449D225fd723
 *   ENV=mainnet forge script scripts/role-regate/DeployRoleRegateProd.s.sol --rpc-url $MAINNET_RPC --broadcast --verify
 */
contract DeployRoleRegateProd is EtherFiDeployerHelper, ContractCodeChecker, RoleRegateProdConfig {
    using stdJson for string;

    function run() public {
        require(isEqualString(getEnv(), "mainnet"), "prod only: ENV must be mainnet");
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        require(DEPLOYER.isDeployer(vm.addr(deployerPk)), "broadcaster is not an EtherFiDeployer deployer");

        if (block.chainid == 10) _deployOptimism(deployerPk);
        else if (block.chainid == 1) _deployEthereum(deployerPk);
        else revert("run on Optimism or Ethereum");
    }

    function _deployOptimism(uint256 pk) internal {
        _checkPins();
        _checkOptimismLiveArgs();

        vm.startBroadcast(pk);
        address lib = _create3(LIB_SALT, vm.getCode("LendReserveLib.sol:LendReserveLib"), "");
        address dpImpl = _create3(OP_DP_IMPL_SALT, type(EtherFiDataProvider).creationCode, "");
        address setters = _create3(SETTERS_SALT, type(CashModuleSetters).creationCode, abi.encode(OP_DATA_PROVIDER));
        address gwImpl = _create3(GW_IMPL_SALT, type(LendGateway).creationCode, abi.encode(OP_DATA_PROVIDER, AAVE_SPOKE));
        address liqImpl = _create3(LIQUIFIER_IMPL_SALT, type(LiquidUSDLiquifierOPModule).creationCode, abi.encode(DEBT_MANAGER, OP_DATA_PROVIDER));
        address frax = _create3(FRAX_SALT, type(FraxModule).creationCode, abi.encode(OP_DATA_PROVIDER, FRAXUSD, FRAX_CUSTODIAN, FRAX_REMOTE_HOP));
        (address[] memory tokens, address[] memory deposits, address[] memory redemptions) = _midasArgs();
        address midas = _create3(MIDAS_SALT, type(MidasModule).creationCode, abi.encode(OP_DATA_PROVIDER, tokens, deposits, redemptions));
        vm.stopBroadcast();

        require(lib == LEND_RESERVE_LIB && dpImpl == OP_DP_IMPL && setters == NEW_SETTERS && gwImpl == NEW_GW_IMPL, "an impl did not land at its pinned address");
        require(liqImpl == NEW_LIQUIFIER_IMPL && frax == NEW_FRAX && midas == NEW_MIDAS, "a module did not land at its pinned address");
        require(lib.code.length > 0, "LendReserveLib has no code");
        require(_codeContainsAddress(gwImpl, LEND_RESERVE_LIB), "LendGateway impl is not linked to the pinned LendReserveLib: pass --libraries");

        console.log("LendReserveLib:            ", lib);
        console.log("EtherFiDataProvider impl:  ", dpImpl);
        console.log("CashModuleSetters:         ", setters);
        console.log("LendGateway impl:          ", gwImpl);
        console.log("LiquidUSDLiquifierOP impl: ", liqImpl);
        console.log("FraxModule:                ", frax);
        console.log("MidasModule:               ", midas);
    }

    function _deployEthereum(uint256 pk) internal {
        _checkPins();
        _checkEthereumLiveArgs();

        vm.startBroadcast(pk);
        address dpImpl = _create3(ETH_DP_IMPL_SALT, type(EtherFiDataProvider).creationCode, "");
        (address[] memory assets, address[] memory tellers) = _depositArgs();
        address deposit = _create3(DEPOSIT_SALT, type(TradingSafeLiquidDepositModule).creationCode, abi.encode(assets, tellers, ETH_DATA_PROVIDER));
        vm.stopBroadcast();

        require(dpImpl == ETH_DP_IMPL && deposit == NEW_DEPOSIT_MODULE, "a contract did not land at its pinned address");
        console.log("Trading EtherFiDataProvider impl:", dpImpl);
        console.log("TradingSafeLiquidDepositModule:  ", deposit);
    }

    /// @dev Every pinned address must be the CREATE3 address of its salt
    function _checkPins() internal view {
        if (block.chainid == 10) {
            require(_predictAddress(LIB_SALT) == LEND_RESERVE_LIB, "LIB pin");
            require(_predictAddress(OP_DP_IMPL_SALT) == OP_DP_IMPL, "OP DP impl pin");
            require(_predictAddress(SETTERS_SALT) == NEW_SETTERS, "setters pin");
            require(_predictAddress(GW_IMPL_SALT) == NEW_GW_IMPL, "gateway impl pin");
            require(_predictAddress(LIQUIFIER_IMPL_SALT) == NEW_LIQUIFIER_IMPL, "liquifier impl pin");
            require(_predictAddress(FRAX_SALT) == NEW_FRAX, "frax pin");
            require(_predictAddress(MIDAS_SALT) == NEW_MIDAS, "midas pin");
        } else {
            require(_predictAddress(ETH_DP_IMPL_SALT) == ETH_DP_IMPL, "ETH DP impl pin");
            require(_predictAddress(DEPOSIT_SALT) == NEW_DEPOSIT_MODULE, "deposit module pin");
        }
    }

    /// @dev The new instances take the live contracts' constructor args; refuse to deploy if those moved
    function _checkOptimismLiveArgs() internal view {
        string memory dep = readDeploymentFile();
        require(dep.readAddress(".addresses.EtherFiDataProvider") == OP_DATA_PROVIDER, "data provider moved");
        require(address(LendGateway(OP_LEND_GATEWAY).spoke()) == AAVE_SPOKE, "gateway spoke changed");
        require(address(LiquidUSDLiquifierOPModule(OP_LIQUIFIER).debtManager()) == DEBT_MANAGER, "liquifier debt manager changed");
        FraxModule live = FraxModule(OLD_FRAX);
        require(live.fraxusd() == FRAXUSD && live.custodian() == FRAX_CUSTODIAN && live.remoteHop() == FRAX_REMOTE_HOP, "live Frax args changed");
        (address[] memory tokens, address[] memory deposits, address[] memory redemptions) = _midasArgs();
        for (uint256 i = 0; i < tokens.length; ++i) {
            (address d, address r) = MidasModule(OLD_MIDAS).vaults(tokens[i]);
            require(d == deposits[i] && r == redemptions[i], "live Midas vaults changed");
        }
    }

    function _checkEthereumLiveArgs() internal view {
        (address[] memory assets, address[] memory tellers) = _depositArgs();
        for (uint256 i = 0; i < assets.length; ++i) {
            require(address(TradingSafeLiquidDepositModule(OLD_DEPOSIT_MODULE).liquidAssetToTeller(assets[i])) == tellers[i], "live deposit teller changed");
        }
    }
}
