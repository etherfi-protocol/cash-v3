// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { EtherFiLiquidModuleWithReferrer } from "../../src/modules/etherfi/EtherFiLiquidModuleWithReferrer.sol";
import { EtherFiStakeModule } from "../../src/modules/etherfi/EtherFiStakeModule.sol";
import { LiquidUSDLiquifierOPModule } from "../../src/modules/etherfi/LiquidUSDLiquifierOP.sol";
import { FraxModule } from "../../src/modules/frax/FraxModule.sol";
import { BeHYPEStakeModule } from "../../src/modules/hype/BeHYPEStakeModule.sol";
import { LendGateway } from "../../src/modules/lend-gateway/LendGateway.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { OpenOceanSwapModule } from "../../src/modules/openocean-swap/OpenOceanSwapModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";

/**
 * @notice Helpers for the seven Optimism dev modules that move assets out of a Safe and therefore
 *         need the LendGateway sandwich. The modules are immutable, so Lend support means deploying
 *         new copies with the old configuration and swapping them in. The liquifier is the one
 *         exception: it sits behind a UUPS proxy, so only its implementation is replaced.
 *
 *         Module order is canonical everywhere (structs, arrays, JSON): openOcean, liquid,
 *         liquidReferrer, frax, stake, midas, beHype.
 */
library CashLendDevModules {
    address internal constant LIQUID_ETH = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address internal constant LIQUID_USD = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address internal constant LIQUID_BTC = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address internal constant EBTC = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address internal constant SETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address internal constant EUSD = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address internal constant LIQUID_RESERVE = 0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898;
    address internal constant LIQUID_EUR = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;
    address internal constant LIQUID_RWA = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;

    struct OldModules {
        address openOcean;
        address liquid;
        address liquidReferrer;
        address frax;
        address stake;
        address midas;
        address beHype;
        address liquifier;
    }

    struct NewModules {
        address openOcean;
        address liquid;
        address liquidReferrer;
        address frax;
        address stake;
        address midas;
        address beHype;
        address liquifierImplementation;
    }

    /// @dev Expected dev policy: every module is default and whitelisted, and exactly the three
    ///      asset-out modules (liquid, liquidReferrer, frax) may request Cash withdrawals.
    ///      The deploy script asserts this against the chain, so drift fails loudly here
    ///      instead of being silently copied forward.
    function requesterFlags() internal pure returns (bool[] memory) {
        bool[] memory flags = new bool[](7);
        flags[1] = true; // liquid
        flags[2] = true; // liquidReferrer
        flags[3] = true; // frax
        return flags;
    }

    /// @dev Reads the eight existing module addresses from the base dev deployment file.
    function readOld(string memory json) internal pure returns (OldModules memory) {
        OldModules memory old;
        old.openOcean = stdJson.readAddress(json, ".addresses.OpenOceanSwapModule");
        old.liquid = stdJson.readAddress(json, ".addresses.EtherFiLiquidModule");
        old.liquidReferrer = stdJson.readAddress(json, ".addresses.EtherFiLiquidModuleWithReferrer");
        old.frax = stdJson.readAddress(json, ".addresses.FraxModule");
        old.stake = stdJson.readAddress(json, ".addresses.EtherFiStakeModule");
        old.midas = stdJson.readAddress(json, ".addresses.MidasModule");
        old.beHype = stdJson.readAddress(json, ".addresses.BeHYPEStakeModule");
        old.liquifier = stdJson.readAddress(json, ".addresses.LiquidUSDLiquifierModule");
        return old;
    }

    /// @dev Confirms the old modules exist and still expose the configuration copied by deployNew.
    function validateOld(OldModules memory old) internal view {
        address[] memory modules = oldAddresses(old);
        for (uint256 i = 0; i < modules.length; ++i) {
            require(modules[i].code.length != 0, "old module code missing");
        }
        require(old.liquifier.code.length != 0, "old liquifier code missing");
        _requireConfiguredLiquidAssets(EtherFiLiquidModule(old.liquid), false);
        _requireConfiguredLiquidAssets(EtherFiLiquidModule(old.liquidReferrer), true);
        (address deposit, address redemption) = MidasModule(old.midas).vaults(LIQUID_RESERVE);
        require(deposit != address(0) && redemption != address(0), "Midas config missing");
    }

    /// @dev Asserts the live chain matches the expected dev policy described by requesterFlags.
    function requireDevPolicy(address dataProvider, address cashModule, OldModules memory old) internal view {
        address[] memory modules = oldAddresses(old);
        address[] memory requesters = ICashModule(cashModule).getWhitelistedModulesCanRequestWithdraw();
        bool[] memory expected = requesterFlags();
        for (uint256 i = 0; i < modules.length; ++i) {
            require(EtherFiDataProvider(dataProvider).isDefaultModule(modules[i]), "old module not default");
            require(EtherFiDataProvider(dataProvider).isWhitelistedModule(modules[i]), "old module not whitelisted");
            require(_contains(requesters, modules[i]) == expected[i], "unexpected requester policy");
        }
        require(EtherFiDataProvider(dataProvider).isDefaultModule(old.liquifier), "liquifier not default");
        require(EtherFiDataProvider(dataProvider).isWhitelistedModule(old.liquifier), "liquifier not whitelisted");
    }

    /// @dev Deploys seven new modules and one implementation for the existing liquifier proxy.
    function deployNew(OldModules memory old, address dataProvider, address debtManager) internal returns (NewModules memory) {
        // The Liquid and Midas contracts use non-enumerable mappings, so rebuild their constructor arrays first.
        (address[] memory baseAssets, address[] memory baseTellers) = _liquidConfig(EtherFiLiquidModule(old.liquid), false);
        (address[] memory referrerAssets, address[] memory referrerTellers) = _liquidConfig(EtherFiLiquidModule(old.liquidReferrer), true);
        address[] memory midasTokens = new address[](3);
        address[] memory deposits = new address[](3);
        address[] memory redemptions = new address[](3);
        midasTokens[0] = LIQUID_RESERVE;
        midasTokens[1] = LIQUID_EUR;
        midasTokens[2] = LIQUID_RWA;
        (deposits[0], redemptions[0]) = MidasModule(old.midas).vaults(LIQUID_RESERVE);
        (deposits[1], redemptions[1]) = MidasModule(old.midas).vaults(LIQUID_EUR);
        (deposits[2], redemptions[2]) = MidasModule(old.midas).vaults(LIQUID_RWA);

        NewModules memory next;
        next.openOcean = address(new OpenOceanSwapModule(OpenOceanSwapModule(old.openOcean).swapRouter(), dataProvider));
        next.liquid = address(new EtherFiLiquidModule(baseAssets, baseTellers, dataProvider, EtherFiLiquidModule(old.liquid).weth()));
        next.liquidReferrer = address(new EtherFiLiquidModuleWithReferrer(referrerAssets, referrerTellers, dataProvider, EtherFiLiquidModule(old.liquidReferrer).weth()));
        next.frax = address(new FraxModule(dataProvider, FraxModule(old.frax).fraxusd(), FraxModule(old.frax).custodian(), FraxModule(old.frax).remoteHop()));
        next.stake = address(new EtherFiStakeModule(dataProvider, address(EtherFiStakeModule(old.stake).syncPool()), EtherFiStakeModule(old.stake).weth(), EtherFiStakeModule(old.stake).weETH()));
        next.midas = address(new MidasModule(dataProvider, midasTokens, deposits, redemptions));
        next.beHype = address(new BeHYPEStakeModule(dataProvider, address(BeHYPEStakeModule(old.beHype).staker()), BeHYPEStakeModule(old.beHype).whype(), BeHYPEStakeModule(old.beHype).beHYPE(), BeHYPEStakeModule(old.beHype).getRefundGasLimit()));
        next.liquifierImplementation = address(new LiquidUSDLiquifierOPModule(debtManager, dataProvider));
        return next;
    }

    /// @dev Copies withdrawal queues to the new liquid modules, using the module-admin role only briefly.
    function copyLiquidQueues(address roleRegistry, OldModules memory old, NewModules memory next) internal {
        RoleRegistry registry = RoleRegistry(roleRegistry);
        bytes32 role = keccak256("MULTISIG_ADMIN_ROLE");
        bool alreadyAdmin = registry.hasRole(role, tx.origin);

        if (!alreadyAdmin) registry.grantRole(role, tx.origin);
        _copyQueues(EtherFiLiquidModule(old.liquid), EtherFiLiquidModule(next.liquid), false);
        _copyQueues(EtherFiLiquidModule(old.liquidReferrer), EtherFiLiquidModule(next.liquidReferrer), true);
        if (!alreadyAdmin) registry.revokeRole(role, tx.origin);
    }

    /// @dev Confirms every new module copied the old constructor and mapping configuration exactly.
    function verifyNewConfig(address dataProvider, address debtManager, OldModules memory old, NewModules memory next) internal view {
        address[] memory modules = newAddresses(next);
        for (uint256 i = 0; i < modules.length; ++i) {
            require(modules[i].code.length != 0, "new module code missing");
        }
        require(next.liquifierImplementation.code.length != 0, "liquifier implementation code missing");
        require(address(LiquidUSDLiquifierOPModule(next.liquifierImplementation).debtManager()) == debtManager, "liquifier DebtManager mismatch");
        require(address(LiquidUSDLiquifierOPModule(next.liquifierImplementation).etherFiDataProvider()) == dataProvider, "liquifier data provider mismatch");

        require(address(OpenOceanSwapModule(next.openOcean).etherFiDataProvider()) == dataProvider, "OpenOcean data provider mismatch");
        require(OpenOceanSwapModule(next.openOcean).swapRouter() == OpenOceanSwapModule(old.openOcean).swapRouter(), "OpenOcean router mismatch");
        require(EtherFiLiquidModule(next.liquid).weth() == EtherFiLiquidModule(old.liquid).weth(), "Liquid WETH mismatch");
        require(EtherFiLiquidModule(next.liquidReferrer).weth() == EtherFiLiquidModule(old.liquidReferrer).weth(), "Liquid referrer WETH mismatch");
        require(FraxModule(next.frax).fraxusd() == FraxModule(old.frax).fraxusd(), "Frax asset mismatch");
        require(FraxModule(next.frax).custodian() == FraxModule(old.frax).custodian(), "Frax custodian mismatch");
        require(FraxModule(next.frax).remoteHop() == FraxModule(old.frax).remoteHop(), "Frax hop mismatch");
        require(address(EtherFiStakeModule(next.stake).syncPool()) == address(EtherFiStakeModule(old.stake).syncPool()), "Stake pool mismatch");
        require(EtherFiStakeModule(next.stake).weth() == EtherFiStakeModule(old.stake).weth(), "Stake WETH mismatch");
        require(EtherFiStakeModule(next.stake).weETH() == EtherFiStakeModule(old.stake).weETH(), "Stake weETH mismatch");
        (address deposit, address redemption) = MidasModule(next.midas).vaults(LIQUID_RESERVE);
        (address oldDeposit, address oldRedemption) = MidasModule(old.midas).vaults(LIQUID_RESERVE);
        require(deposit == oldDeposit && redemption == oldRedemption, "Midas mismatch for LIQUID_RESERVE");
        (deposit, redemption) = MidasModule(next.midas).vaults(LIQUID_EUR);
        (oldDeposit, oldRedemption) = MidasModule(old.midas).vaults(LIQUID_EUR);
        require(deposit == oldDeposit && redemption == oldRedemption, "Midas mismatch for LIQUID_EUR");
        (deposit, redemption) = MidasModule(next.midas).vaults(LIQUID_RWA);
        (oldDeposit, oldRedemption) = MidasModule(old.midas).vaults(LIQUID_RWA);
        require(deposit == oldDeposit && redemption == oldRedemption, "Midas mismatch for LIQUID_RWA");
        require(address(BeHYPEStakeModule(next.beHype).staker()) == address(BeHYPEStakeModule(old.beHype).staker()), "BeHYPE staker mismatch");
        require(BeHYPEStakeModule(next.beHype).whype() == BeHYPEStakeModule(old.beHype).whype(), "BeHYPE WHYPE mismatch");
        require(BeHYPEStakeModule(next.beHype).beHYPE() == BeHYPEStakeModule(old.beHype).beHYPE(), "BeHYPE asset mismatch");
        require(BeHYPEStakeModule(next.beHype).getRefundGasLimit() == BeHYPEStakeModule(old.beHype).getRefundGasLimit(), "BeHYPE gas mismatch");
        _requireCopiedLiquidConfig(EtherFiLiquidModule(old.liquid), EtherFiLiquidModule(next.liquid), false);
        _requireCopiedLiquidConfig(EtherFiLiquidModule(old.liquidReferrer), EtherFiLiquidModule(next.liquidReferrer), true);
    }

    /// @dev Enables the new modules with the dev policy. The old modules stay enabled (default,
    ///      whitelisted, requesters) so existing Safes keep working during the gradual migration;
    ///      a later pass retires them.
    function activate(address dataProvider, address cashModule, OldModules memory, NewModules memory next) internal {
        address[] memory newModules = newAddresses(next);
        bool[] memory yes = _bools(7, true);

        // To retire the old modules later:
        //   address[] memory oldModules = oldAddresses(old);
        //   bool[] memory no = _bools(7, false);
        //   ICashModule(cashModule).configureModulesCanRequestWithdraw(oldModules, no);
        //   EtherFiDataProvider(dataProvider).configureDefaultModules(oldModules, no);
        //   EtherFiDataProvider(dataProvider).configureModules(oldModules, no);
        EtherFiDataProvider(dataProvider).configureDefaultModules(newModules, yes);
        ICashModule(cashModule).configureModulesCanRequestWithdraw(newModules, requesterFlags());
    }

    /// @dev Grants every active sandwich consumer permission to call the gateway.
    function enableDrivers(LendGateway gateway, OldModules memory old, NewModules memory next) internal {
        address[] memory active = newAddresses(next);
        for (uint256 i = 0; i < active.length; ++i) {
            gateway.setDriver(active[i], true);
        }
        gateway.setDriver(old.liquifier, true);
    }

    /// @dev Restores the old modules to the dev policy and fully retires the new ones. Idempotent, so a
    ///      partially broadcast rollback can rerun it.
    function restoreOld(address dataProvider, address cashModule, LendGateway gateway, address[] memory oldModules, address[] memory newModules) internal {
        require(oldModules.length == 7 && newModules.length == 7, "module list length mismatch");
        bool[] memory yes = _bools(7, true);
        bool[] memory no = _bools(7, false);

        EtherFiDataProvider(dataProvider).configureModules(oldModules, yes);
        EtherFiDataProvider(dataProvider).configureDefaultModules(oldModules, yes);
        ICashModule(cashModule).configureModulesCanRequestWithdraw(oldModules, requesterFlags());

        ICashModule(cashModule).configureModulesCanRequestWithdraw(newModules, no);
        for (uint256 i = 0; i < newModules.length; ++i) {
            gateway.setDriver(newModules[i], false);
        }
        EtherFiDataProvider(dataProvider).configureDefaultModules(newModules, no);
        EtherFiDataProvider(dataProvider).configureModules(newModules, no);
    }

    /// @dev Confirms the new modules are live with the dev policy and the old ones remain enabled
    ///      with the same policy (kept active during the gradual migration) but without gateway access.
    function verifyActive(address dataProvider, address cashModule, LendGateway gateway, address[] memory oldModules, address[] memory newModules) internal view {
        require(oldModules.length == 7 && newModules.length == 7, "module list length mismatch");
        address[] memory requesters = ICashModule(cashModule).getWhitelistedModulesCanRequestWithdraw();
        bool[] memory expected = requesterFlags();

        for (uint256 i = 0; i < 7; ++i) {
            require(EtherFiDataProvider(dataProvider).isDefaultModule(newModules[i]), "new module not default");
            require(EtherFiDataProvider(dataProvider).isWhitelistedModule(newModules[i]), "new module not whitelisted");
            require(gateway.isDriver(newModules[i]), "new module not driver");
            require(_contains(requesters, newModules[i]) == expected[i], "new requester mismatch");
            require(EtherFiDataProvider(dataProvider).isDefaultModule(oldModules[i]), "old module no longer default");
            require(EtherFiDataProvider(dataProvider).isWhitelistedModule(oldModules[i]), "old module no longer whitelisted");
            require(!gateway.isDriver(oldModules[i]), "old module unexpectedly a driver");
            require(_contains(requesters, oldModules[i]) == expected[i], "old requester mismatch");
        }
    }

    /// @dev Confirms the old modules are back with the dev policy and the new ones are fully retired.
    function verifyRestored(address dataProvider, address cashModule, LendGateway gateway, address[] memory oldModules, address[] memory newModules) internal view {
        require(oldModules.length == 7 && newModules.length == 7, "module list length mismatch");
        address[] memory requesters = ICashModule(cashModule).getWhitelistedModulesCanRequestWithdraw();
        bool[] memory expected = requesterFlags();

        for (uint256 i = 0; i < 7; ++i) {
            require(EtherFiDataProvider(dataProvider).isDefaultModule(oldModules[i]), "old module not restored as default");
            require(EtherFiDataProvider(dataProvider).isWhitelistedModule(oldModules[i]), "old module not restored as whitelisted");
            require(_contains(requesters, oldModules[i]) == expected[i], "old requester not restored");
            require(!EtherFiDataProvider(dataProvider).isDefaultModule(newModules[i]), "new module still default");
            require(!EtherFiDataProvider(dataProvider).isWhitelistedModule(newModules[i]), "new module still whitelisted");
            require(!_contains(requesters, newModules[i]), "new requester remains");
            require(!gateway.isDriver(newModules[i]), "new module still driver");
        }
    }

    /// @dev Returns the old direct modules in canonical order.
    function oldAddresses(OldModules memory old) internal pure returns (address[] memory) {
        address[] memory addresses = new address[](7);
        addresses[0] = old.openOcean;
        addresses[1] = old.liquid;
        addresses[2] = old.liquidReferrer;
        addresses[3] = old.frax;
        addresses[4] = old.stake;
        addresses[5] = old.midas;
        addresses[6] = old.beHype;
        return addresses;
    }

    /// @dev Returns the new direct modules in canonical order.
    function newAddresses(NewModules memory next) internal pure returns (address[] memory) {
        address[] memory addresses = new address[](7);
        addresses[0] = next.openOcean;
        addresses[1] = next.liquid;
        addresses[2] = next.liquidReferrer;
        addresses[3] = next.frax;
        addresses[4] = next.stake;
        addresses[5] = next.midas;
        addresses[6] = next.beHype;
        return addresses;
    }

    /// @dev Serializes the new direct modules as a name-keyed JSON object for the deployment record.
    function serializeNew(NewModules memory next) internal returns (string memory) {
        string memory obj = "cash-lend-new-modules";
        stdJson.serialize(obj, "openOcean", next.openOcean);
        stdJson.serialize(obj, "liquid", next.liquid);
        stdJson.serialize(obj, "liquidReferrer", next.liquidReferrer);
        stdJson.serialize(obj, "frax", next.frax);
        stdJson.serialize(obj, "stake", next.stake);
        stdJson.serialize(obj, "midas", next.midas);
        return stdJson.serialize(obj, "beHype", next.beHype);
    }

    /// @dev Reads the new direct modules from the deployment record in canonical order.
    function readNew(string memory record) internal pure returns (address[] memory) {
        address[] memory addresses = new address[](7);
        addresses[0] = stdJson.readAddress(record, ".newModules.openOcean");
        addresses[1] = stdJson.readAddress(record, ".newModules.liquid");
        addresses[2] = stdJson.readAddress(record, ".newModules.liquidReferrer");
        addresses[3] = stdJson.readAddress(record, ".newModules.frax");
        addresses[4] = stdJson.readAddress(record, ".newModules.stake");
        addresses[5] = stdJson.readAddress(record, ".newModules.midas");
        addresses[6] = stdJson.readAddress(record, ".newModules.beHype");
        return addresses;
    }

    /// @dev Rebuilds a NewModules struct from its canonical array in the deployment record.
    function newFromAddresses(address[] memory addresses, address liquifierImplementation) internal pure returns (NewModules memory) {
        require(addresses.length == 7, "new module length mismatch");
        NewModules memory next;
        next.openOcean = addresses[0];
        next.liquid = addresses[1];
        next.liquidReferrer = addresses[2];
        next.frax = addresses[3];
        next.stake = addresses[4];
        next.midas = addresses[5];
        next.beHype = addresses[6];
        next.liquifierImplementation = liquifierImplementation;
        return next;
    }

    /// @dev Confirms every known liquid asset has a teller before deployment starts.
    function _requireConfiguredLiquidAssets(EtherFiLiquidModule module, bool referrer) private view {
        address[] memory assets = _liquidAssets(referrer);
        for (uint256 i = 0; i < assets.length; ++i) {
            require(address(module.liquidAssetToTeller(assets[i])) != address(0), "liquid teller missing");
        }
    }

    /// @dev Confirms tellers and optional withdrawal queues were copied exactly.
    function _requireCopiedLiquidConfig(EtherFiLiquidModule oldModule, EtherFiLiquidModule newModule, bool referrer) private view {
        address[] memory assets = _liquidAssets(referrer);
        for (uint256 i = 0; i < assets.length; ++i) {
            require(newModule.liquidAssetToTeller(assets[i]) == oldModule.liquidAssetToTeller(assets[i]), "liquid teller mismatch");
            require(newModule.liquidWithdrawQueue(assets[i]) == oldModule.liquidWithdrawQueue(assets[i]), "liquid queue mismatch");
        }
    }

    /// @dev Reads constructor assets and tellers from an existing liquid module.
    function _liquidConfig(EtherFiLiquidModule module, bool referrer) private view returns (address[] memory, address[] memory) {
        address[] memory assets = _liquidAssets(referrer);
        address[] memory tellers = new address[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            tellers[i] = address(module.liquidAssetToTeller(assets[i]));
        }
        return (assets, tellers);
    }

    /// @dev Returns the known asset keys for either liquid module variant.
    function _liquidAssets(bool referrer) private pure returns (address[] memory) {
        address[] memory assets = new address[](referrer ? 6 : 4);
        assets[0] = LIQUID_ETH;
        assets[1] = LIQUID_USD;
        assets[2] = LIQUID_BTC;
        assets[3] = EBTC;
        if (referrer) {
            assets[4] = SETHFI;
            assets[5] = EUSD;
        }
        return assets;
    }

    /// @dev Copies every configured withdrawal queue from one liquid module to another.
    function _copyQueues(EtherFiLiquidModule oldModule, EtherFiLiquidModule newModule, bool referrer) private {
        address[] memory assets = _liquidAssets(referrer);
        for (uint256 i = 0; i < assets.length; ++i) {
            address queue = oldModule.liquidWithdrawQueue(assets[i]);
            if (queue != address(0)) newModule.setLiquidAssetWithdrawQueue(assets[i], queue);
        }
    }

    /// @dev Builds a boolean array for batch configuration calls.
    function _bools(uint256 length, bool value) private pure returns (bool[] memory) {
        bool[] memory values = new bool[](length);
        for (uint256 i = 0; i < length; ++i) {
            values[i] = value;
        }
        return values;
    }

    /// @dev Returns whether an address appears in a memory array.
    function _contains(address[] memory values, address value) private pure returns (bool) {
        for (uint256 i = 0; i < values.length; ++i) {
            if (values[i] == value) return true;
        }
        return false;
    }
}
