// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console2 } from "forge-std/console2.sol";

import { RoleRegistry } from "../../../src/role-registry/RoleRegistry.sol";
import { EtherFiDataProvider } from "../../../src/data-provider/EtherFiDataProvider.sol";
import { CashModuleCore } from "../../../src/modules/cash/CashModuleCore.sol";
import { CashModuleSetters } from "../../../src/modules/cash/CashModuleSetters.sol";
import { ICashModule } from "../../../src/interfaces/ICashModule.sol";
import { DebtManagerCore } from "../../../src/debt-manager/DebtManagerCore.sol";
import { DebtManagerAdmin } from "../../../src/debt-manager/DebtManagerAdmin.sol";
import { IDebtManager } from "../../../src/interfaces/IDebtManager.sol";
import { PriceProviderV2 } from "../../../src/oracle/PriceProviderV2.sol";
import { AcrossSwapModule } from "../../../src/across/AcrossSwapModule.sol";
import { EnsoSwapModule } from "../../../src/enso/EnsoSwapModule.sol";
import { StockWithdrawModule } from "../../../src/stock-withdraw/StockWithdrawModule.sol";
import { LendGateway } from "../../../src/modules/lend-gateway/LendGateway.sol";
import { TopUpDest } from "../../../src/top-up/TopUpDest.sol";
import { SettlementDispatcherV2 } from "../../../src/settlement-dispatcher/SettlementDispatcherV2.sol";
import { BinSponsor } from "../../../src/interfaces/ICashModule.sol";
import { CashbackDispatcher } from "../../../src/cashback-dispatcher/CashbackDispatcher.sol";
import { EtherFiLiquidModule } from "../../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { StargateModule } from "../../../src/modules/stargate/StargateModule.sol";
import { BeHYPEStakeModule } from "../../../src/modules/hype/BeHYPEStakeModule.sol";
import { MidasModule } from "../../../src/modules/midas/MidasModule.sol";
import { EtherFiDeployer } from "../../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../../utils/Utils.sol";
import { ContractCodeChecker } from "../../utils/ContractCodeChecker.sol";

/**
 * @notice Post-broadcast check for `DeployRoleRegatingOPDev`: every upgraded proxy's on-chain
 *         impl byte-matches a fresh local compile (address embeds reconciled, per
 *         `ContractCodeChecker`), and the end state - old modules untouched, new modules wired
 *         in alongside them - holds. Read-only: makes no state-changing calls.
 *
 * Usage:
 *   source .env && forge script scripts/dev/role-regating/VerifyRoleRegatingOPDev.s.sol \
 *     --rpc-url $OPTIMISM_RPC
 */
contract VerifyRoleRegatingOPDev is Utils, ContractCodeChecker {
    EtherFiDeployer private constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);
    address private constant DEV_ADMIN = 0x7D829d50aAF400B8B29B3b311F4aD70aD819DC6E;

    address private constant DATA_PROVIDER = 0x4a9c44c97BBf6079db37C4769AebE425bBcDD09a;
    address private constant ROLE_REGISTRY = 0xa322a04d1e2Cb44672473740F9F35B057FA29CFB;
    address private constant CASH_MODULE = 0xA4F3A3229FDFBfc7A30FEAC42337d931E85Dc969;
    address private constant DEBT_MANAGER = 0x92adCa2e95Eb9aCcA65a7dBa1A03ad5246d8f4F4;
    address private constant PRICE_PROVIDER = 0x7d7947D1ace9088048AaB067cF2F54eA1F762a4f;
    address private constant ACROSS_SWAP_MODULE = 0x7EF26F117a5C4f84A0caE2f79a61Af90Fb1D8e8A;
    address private constant ENSO_SWAP_MODULE = 0xd6B0c55f4F2bFdFe9355e5Af1Bac0f3DAb101DC2;
    address private constant STOCK_WITHDRAW_MODULE = 0x367c0f68599c4B75DBeC7500dFA6dB7F55a1Dd0c;
    address private constant LEND_GATEWAY = 0x26ba458CFc67e73dB227AB7BBd71d33d04865695;
    address private constant CASHBACK_DISPATCHER = 0x88758BDA231b8d989AFA0B408FfFD1dF67021F10;
    address private constant TOP_UP_DEST = 0x06fe42Cf3C63412f1955758ce2798709476a38fd;
    address private constant SETTLEMENT_RAIN = 0x26d90676C6aeF2a09Cf383af499cc67E9D6ad7CA;
    address private constant SETTLEMENT_REAP = 0xea6e574886797A65eD22CcF2307e48a83C355771;
    address private constant SETTLEMENT_PIX = 0xe61c5A65d26fDf27260cf34281a691a227C34bA3;
    address private constant SETTLEMENT_CARD_ORDER = 0x8e7AB8E9037FBd6C91f3758c6c9E2abf92675Aea;

    address private constant OLD_LIQUID_MODULE = 0xC5B64C973ac9D8fd04c77addC43970ce08b0dA9b;
    address private constant OLD_LIQUID_MODULE_REFERRER = 0xC40C1C57fdb3B1480D791298E8A059ae7872A6c1;
    address private constant OLD_STARGATE_MODULE = 0x88626Bd138A5435733675f4Bcd8e156ba1282911;
    address private constant OLD_BEHYPE_STAKE_MODULE = 0xACF460cacB308Ca12773FBD1729944e9eb8EF185;
    address private constant OLD_MIDAS_MODULE = 0x9AB4a3943E0edcE47fE2E746Ca50957afFec796c;

    string private constant SALT_PREFIX = "RoleRegating.Dev.v1.OP.";

    function run() external {
        require(block.chainid == 10, "must run on Optimism");

        _verifyProxyImpls();
        address liquidModule = _predicted("EtherFiLiquidModule");
        address liquidReferrerModule = _predicted("EtherFiLiquidModuleWithReferrer");
        address stargateModule = _predicted("StargateModule");
        address beHypeModule = _predicted("BeHYPEStakeModule");
        address midasModule = _predicted("MidasModule");

        _verifyNewModulesDeployed(liquidModule, liquidReferrerModule, stargateModule, beHypeModule, midasModule);
        _verifyModuleWiring(liquidModule, liquidReferrerModule, stargateModule, beHypeModule, midasModule);
        _verifyOldModulesUntouched();
        _verifyGovernance();

        console2.log("");
        console2.log("=== ALL CHECKS PASSED ===");
    }

    function _verifyProxyImpls() internal {
        console2.log("=== Verifying proxy bytecode (address embeds reconciled) ===");
        requireCodeMatchAllowingAddressEmbeds("EtherFiDataProvider", _currentImpl(DATA_PROVIDER), address(new EtherFiDataProvider()));
        requireCodeMatchAllowingAddressEmbeds("CashModule (core)", _currentImpl(CASH_MODULE), address(new CashModuleCore(DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("CashModule (setters)", CashModuleCore(CASH_MODULE).getCashModuleSetters(), address(new CashModuleSetters(DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("DebtManager (core)", _currentImpl(DEBT_MANAGER), address(new DebtManagerCore(DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("DebtManager (admin)", IDebtManager(DEBT_MANAGER).getDebtManagerAdmin(), address(new DebtManagerAdmin(DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("PriceProvider", _currentImpl(PRICE_PROVIDER), address(new PriceProviderV2()));
        requireCodeMatchAllowingAddressEmbeds("AcrossSwapModule", _currentImpl(ACROSS_SWAP_MODULE), address(new AcrossSwapModule(DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("EnsoSwapModule", _currentImpl(ENSO_SWAP_MODULE), address(new EnsoSwapModule(DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("StockWithdrawModule", _currentImpl(STOCK_WITHDRAW_MODULE), address(new StockWithdrawModule(DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("LendGateway", _currentImpl(LEND_GATEWAY), address(new LendGateway(DATA_PROVIDER, address(LendGateway(payable(LEND_GATEWAY)).spoke()))));
        requireCodeMatchAllowingAddressEmbeds("TopUpDest", _currentImpl(TOP_UP_DEST), address(new TopUpDest(DATA_PROVIDER, address(TopUpDest(payable(TOP_UP_DEST)).weth()))));
        requireCodeMatchAllowingAddressEmbeds("SettlementDispatcherRain", _currentImpl(SETTLEMENT_RAIN), address(new SettlementDispatcherV2(BinSponsor.Rain, DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("SettlementDispatcherReap", _currentImpl(SETTLEMENT_REAP), address(new SettlementDispatcherV2(BinSponsor.Reap, DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("SettlementDispatcherPix", _currentImpl(SETTLEMENT_PIX), address(new SettlementDispatcherV2(BinSponsor.PIX, DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("SettlementDispatcherCardOrder", _currentImpl(SETTLEMENT_CARD_ORDER), address(new SettlementDispatcherV2(BinSponsor.CardOrder, DATA_PROVIDER)));
        requireCodeMatchAllowingAddressEmbeds("CashbackDispatcher", _currentImpl(CASHBACK_DISPATCHER), address(new CashbackDispatcher(DATA_PROVIDER)));
    }

    function _verifyNewModulesDeployed(address liquidModule, address liquidReferrerModule, address stargateModule, address beHypeModule, address midasModule) internal view {
        console2.log("=== Verifying new immutable modules are deployed ===");
        require(liquidModule.code.length > 0, "EtherFiLiquidModule not deployed");
        require(liquidReferrerModule.code.length > 0, "EtherFiLiquidModuleWithReferrer not deployed");
        require(stargateModule.code.length > 0, "StargateModule not deployed");
        require(beHypeModule.code.length > 0, "BeHYPEStakeModule not deployed");
        require(midasModule.code.length > 0, "MidasModule not deployed");
        console2.log("  [OK] all five new modules have code at their predicted addresses");
    }

    function _verifyModuleWiring(address liquidModule, address liquidReferrerModule, address stargateModule, address beHypeModule, address midasModule) internal view {
        console2.log("=== Verifying new module wiring ===");
        EtherFiDataProvider provider = EtherFiDataProvider(DATA_PROVIDER);
        LendGateway gateway = LendGateway(payable(LEND_GATEWAY));

        require(provider.isDefaultModule(liquidModule), "EtherFiLiquidModule not default");
        require(provider.isDefaultModule(liquidReferrerModule), "EtherFiLiquidModuleWithReferrer not default");
        require(provider.isDefaultModule(stargateModule), "StargateModule not default");
        require(provider.isDefaultModule(beHypeModule), "BeHYPEStakeModule not default");
        require(provider.isDefaultModule(midasModule), "MidasModule not default");

        require(gateway.isDriver(liquidModule), "EtherFiLiquidModule not a gateway driver");
        require(gateway.isDriver(liquidReferrerModule), "EtherFiLiquidModuleWithReferrer not a gateway driver");
        require(!gateway.isDriver(stargateModule), "StargateModule unexpectedly a gateway driver");
        require(gateway.isDriver(beHypeModule), "BeHYPEStakeModule not a gateway driver");
        require(gateway.isDriver(midasModule), "MidasModule not a gateway driver");

        require(_isWithdrawRequester(liquidModule), "EtherFiLiquidModule not a withdraw-requester");
        require(_isWithdrawRequester(liquidReferrerModule), "EtherFiLiquidModuleWithReferrer not a withdraw-requester");
        require(_isWithdrawRequester(stargateModule), "StargateModule not a withdraw-requester");

        for (uint256 i = 0; i < 4; ++i) {
            address asset = _liquidCandidate(i);
            address oldQueue = EtherFiLiquidModule(OLD_LIQUID_MODULE).getLiquidAssetWithdrawQueue(asset);
            if (oldQueue == address(0)) continue;
            require(EtherFiLiquidModule(liquidModule).getLiquidAssetWithdrawQueue(asset) == oldQueue, "liquid withdraw queue not copied");
        }
        console2.log("  [OK] new modules default, driver-set and withdraw-requester status match the old ones");
    }

    function _verifyOldModulesUntouched() internal view {
        console2.log("=== Verifying old modules were left exactly as-is ===");
        EtherFiDataProvider provider = EtherFiDataProvider(DATA_PROVIDER);
        LendGateway gateway = LendGateway(payable(LEND_GATEWAY));

        require(provider.isDefaultModule(OLD_LIQUID_MODULE), "old EtherFiLiquidModule no longer default");
        require(provider.isDefaultModule(OLD_LIQUID_MODULE_REFERRER), "old EtherFiLiquidModuleWithReferrer no longer default");
        require(provider.isDefaultModule(OLD_STARGATE_MODULE), "old StargateModule no longer default");
        require(provider.isDefaultModule(OLD_BEHYPE_STAKE_MODULE), "old BeHYPEStakeModule no longer default");
        require(provider.isDefaultModule(OLD_MIDAS_MODULE), "old MidasModule no longer default");

        require(provider.isWhitelistedModule(OLD_LIQUID_MODULE), "old EtherFiLiquidModule no longer whitelisted");
        require(provider.isWhitelistedModule(OLD_LIQUID_MODULE_REFERRER), "old EtherFiLiquidModuleWithReferrer no longer whitelisted");
        require(provider.isWhitelistedModule(OLD_STARGATE_MODULE), "old StargateModule no longer whitelisted");
        require(provider.isWhitelistedModule(OLD_BEHYPE_STAKE_MODULE), "old BeHYPEStakeModule no longer whitelisted");
        require(provider.isWhitelistedModule(OLD_MIDAS_MODULE), "old MidasModule no longer whitelisted");

        require(gateway.isDriver(OLD_LIQUID_MODULE), "old EtherFiLiquidModule no longer a gateway driver");
        require(gateway.isDriver(OLD_LIQUID_MODULE_REFERRER), "old EtherFiLiquidModuleWithReferrer no longer a gateway driver");
        require(gateway.isDriver(OLD_BEHYPE_STAKE_MODULE), "old BeHYPEStakeModule no longer a gateway driver");
        require(gateway.isDriver(OLD_MIDAS_MODULE), "old MidasModule no longer a gateway driver");

        require(_isWithdrawRequester(OLD_LIQUID_MODULE), "old EtherFiLiquidModule no longer a withdraw-requester");
        require(_isWithdrawRequester(OLD_LIQUID_MODULE_REFERRER), "old EtherFiLiquidModuleWithReferrer no longer a withdraw-requester");
        require(_isWithdrawRequester(OLD_STARGATE_MODULE), "old StargateModule no longer a withdraw-requester");

        console2.log("  [OK] old modules unchanged: still default, whitelisted, driver-set and withdraw-requesters");
    }

    function _verifyGovernance() internal view {
        console2.log("=== Verifying governance ===");
        RoleRegistry registry = RoleRegistry(ROLE_REGISTRY);
        require(registry.owner() == DEV_ADMIN, "RoleRegistry owner is not DEV_ADMIN");
        require(registry.hasRole(registry.ADMIN_ROLE(), DEV_ADMIN), "DEV_ADMIN lacks ADMIN_ROLE");
        require(registry.hasRole(registry.ADMIN_TIMELOCK_ROLE(), DEV_ADMIN), "DEV_ADMIN lacks ADMIN_TIMELOCK_ROLE");
        console2.log("  [OK] DEV_ADMIN owns the registry and holds both roles");
    }

    function _isWithdrawRequester(address module) internal view returns (bool) {
        address[] memory requesters = ICashModule(CASH_MODULE).getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < requesters.length; ++i) {
            if (requesters[i] == module) return true;
        }
        return false;
    }

    function _liquidCandidate(uint256 i) internal pure returns (address) {
        if (i == 0) return 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
        if (i == 1) return 0x5f46d540b6eD704C3c8789105F30E075AA900726;
        if (i == 2) return 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
        return 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    }

    function _predicted(string memory name) internal view returns (address) {
        return DEPLOYER.getDeterministicAddress(getSalt(string.concat(SALT_PREFIX, name)));
    }

    function _currentImpl(address proxy) internal view returns (address) {
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        return address(uint160(uint256(vm.load(proxy, slot))));
    }
}
