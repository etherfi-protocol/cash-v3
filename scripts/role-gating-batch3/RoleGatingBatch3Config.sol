// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiLiquidModule } from "../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { MidasModule } from "../../src/modules/midas/MidasModule.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @title RoleGatingBatch3Config
 * @notice Single source of truth shared by DeployRoleGatingBatch3, RoleGatingBatch3Cutover and
 *         VerifyRoleGatingBatch3: governance addresses, salts, live-address resolution and the
 *         candidate lists used to copy immutable module config. All three inherit this so the
 *         verifier's "impl slot == predicted CREATE3 address" check can never drift from what the
 *         deploy script actually deployed.
 *
 *         Batch 3 finishes the PR #289 role re-gating rollout. Batches 1 (OP) and 2 (top-up chains)
 *         already upgraded the RoleRegistry, settlement dispatchers, TopUpDest, CashbackDispatcher,
 *         liquifier and TopUpFactory. Batch 3 covers everything that is still on pre-PR code:
 *
 *         Optimism, cash stack (RoleRegistry owner = 2-day upgrade timelock):
 *           proxies  CashModule (core + setters), DebtManager (core + admin), EtherFiDataProvider,
 *                    PriceProvider (PriceProviderV2), AcrossSwapModule, EnsoSwapModule, LendGateway,
 *                    StockWithdrawModule
 *           modules  EtherFiLiquidModule, EtherFiLiquidModuleWithReferrer, StargateModule,
 *                    BeHYPEStakeModule, MidasModule — immutable, so redeployed with the live
 *                    config and swapped in as default modules
 *         Optimism, trading stack (own RoleRegistry, owner = governance Safe):
 *           RoleRegistry, EtherFiDataProvider
 *         Ethereum, cash stack (RoleRegistry owner = 2-day upgrade timelock):
 *           StockUnwrapper
 *         Ethereum, trading stack (own RoleRegistry, owner = governance Safe):
 *           RoleRegistry, EtherFiDataProvider, PriceProvider (PriceProviderV2), AcrossSwapModule,
 *           EnsoSwapModule, TradingLens
 *
 *         Deliberately NOT in batch 3: TradingSafeFactory (PR only changes doc comments),
 *         TradingSafe / TopUp beacon impls and TradingSafeWithdrawModule (untouched by the PR),
 *         and retiring the OLD modules (they stay whitelisted + withdraw-requesters so in-flight
 *         bridges can drain; retire them later after scripts/lend/check-pending-withdrawals.sh).
 */
abstract contract RoleGatingBatch3Config is Utils {
    // ─────────────────────────────── governance ───────────────────────────────

    /// @dev Cash governance multisig (3/6): proposer/executor on both timelocks, owner of the
    ///      trading RoleRegistry, and ADMIN_ROLE holder
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @dev 2-day upgrade timelock — owner of the cash RoleRegistry on OP and ETH since batches 1/2
    address internal constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;
    /// @dev 8h operating timelock — holds ADMIN_TIMELOCK_ROLE on the cash RoleRegistry (and, after
    ///      this batch, on the trading RoleRegistry)
    address internal constant OPERATING_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;

    uint256 internal constant UPGRADE_DELAY = 2 days;
    uint256 internal constant OPERATING_DELAY = 8 hours;

    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant ADMIN_TIMELOCK_ROLE = keccak256("ADMIN_TIMELOCK_ROLE");

    bytes32 internal constant TL_PREDECESSOR = bytes32(0);
    bytes32 internal constant TL_SALT_CASH = keccak256("RoleGatingBatch3Cutover.CashUpgrades");
    bytes32 internal constant TL_SALT_MODULES = keccak256("RoleGatingBatch3Cutover.ModuleSwap");

    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Permissioned CREATE3 deployer (never a public factory: our salts are public, so a
    ///      public factory would let anyone squat the addresses — see scripts/lend/CashLendProdConfig.sol)
    EtherFiDeployer internal constant DEPLOYER = EtherFiDeployer(0xFCD957b5913d607BF2222280093421B1e2Af6f30);

    string internal constant SALT_PREFIX = "RoleGatingBatch3.";

    // ─────────────────────────────── module config candidates (Optimism) ───────────────────────────────

    // Immutable modules take their config in the constructor and the mappings are not enumerable,
    // so the live values are copied for every candidate the old module has configured. An asset
    // listed on prod after this file was written MUST be appended here before deploying — the
    // deploy script cannot see it otherwise.
    address internal constant LIQUID_ETH = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address internal constant LIQUID_USD = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address internal constant LIQUID_BTC = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address internal constant EBTC = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address internal constant SETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address internal constant EUSD = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address internal constant LIQUID_RESERVE = 0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898;
    address internal constant LIQUID_EUR = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;
    address internal constant LIQUID_RWA = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;

    address internal constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant WEETH = 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF;
    address internal constant ETHFI = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;
    address internal constant WHYPE = 0xd83E3d560bA6F05094d9D8B3EB8aaEA571D1864E;
    address internal constant BEHYPE = 0xA519AfBc91986c0e7501d7e34968FEE51CD901aC;
    address internal constant EURC = 0xDCB612005417Dc906fF72c87DF732e5a90D49e11;
    /// @dev Added to the live StargateModule after deploy (AssetConfigSet at OP blocks 156470048 / 157379291)
    address internal constant IPAXG = 0x41a7f2bb9789199654c206f09392674c1Af6676c;
    address internal constant USDT0 = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;

    function _liquidAssetCandidates() internal pure returns (address[9] memory) {
        return [LIQUID_ETH, LIQUID_USD, LIQUID_BTC, EBTC, SETHFI, EUSD, LIQUID_RESERVE, LIQUID_EUR, LIQUID_RWA];
    }

    function _midasTokenCandidates() internal pure returns (address[3] memory) {
        return [LIQUID_RESERVE, LIQUID_EUR, LIQUID_RWA];
    }

    function _stargateAssetCandidates() internal pure returns (address[8] memory) {
        return [USDC, WEETH, ETHFI, WHYPE, BEHYPE, EURC, IPAXG, USDT0];
    }

    // ─────────────────────────────── live addresses ───────────────────────────────

    /// @dev Old immutable modules in canonical order; index-aligned with _moduleSaltNames / _moduleKeys
    uint256 internal constant N_MODULES = 5;

    function _oldModuleKeys() internal pure returns (string[5] memory) {
        return ["EtherFiLiquidModule", "EtherFiLiquidModuleWithReferrer", "StargateModule", "BeHYPEStakeModule", "MidasModule"];
    }

    function _moduleSaltNames() internal pure returns (string[5] memory) {
        return ["LiquidModule", "LiquidReferrerModule", "StargateModule", "BeHYPEStakeModule", "MidasModule"];
    }

    /// @dev Record keys in role-gating-batch3.json for the new modules
    function _moduleKeys() internal pure returns (string[5] memory) {
        return ["liquidModule", "liquidReferrerModule", "stargateModule", "beHypeStakeModule", "midasModule"];
    }

    /// @dev Record key for the module a new module replaced, e.g. `old_liquidModule`
    function _oldModuleRecordKey(uint256 i) internal pure returns (string memory) {
        return string.concat("old_", _moduleKeys()[i]);
    }

    /// @dev Whether the module runs the Aave-gateway sandwich and so must be a LendGateway driver
    function _isGatewayDriver(uint256 i) internal pure returns (bool) {
        return i != 2; // everything but StargateModule
    }

    struct OpLive {
        address roleRegistry;
        address dataProvider;
        address cashModule;
        address debtManager;
        address priceProvider;
        address across;
        address enso;
        address lendGateway;
        address stockWithdrawModule;
        address[5] oldModules;
        address tradingRoleRegistry;
        address tradingDataProvider;
    }

    struct EthLive {
        address roleRegistry;
        address stockUnwrapper;
        address tradingRoleRegistry;
        address tradingDataProvider;
        address tradingPriceProvider;
        address across;
        address enso;
        address tradingLens;
    }

    function _readOpLive() internal view returns (OpLive memory l) {
        require(block.chainid == 10, "not Optimism");
        string memory cash = readDeploymentFile();
        l.roleRegistry = _cashAddr(cash, "RoleRegistry");
        l.dataProvider = _cashAddr(cash, "EtherFiDataProvider");
        l.cashModule = _cashAddr(cash, "CashModule");
        l.debtManager = _cashAddr(cash, "DebtManager");
        l.priceProvider = _cashAddr(cash, "PriceProvider");
        l.across = _cashAddr(cash, "AcrossSwapModule");
        l.enso = _cashAddr(cash, "EnsoSwapModule");
        l.lendGateway = _cashAddr(cash, "LendGateway");
        l.stockWithdrawModule = _cashAddr(cash, "StockWithdrawModule");
        string[5] memory keys = _oldModuleKeys();
        for (uint256 i = 0; i < N_MODULES; ++i) {
            l.oldModules[i] = _cashAddr(cash, keys[i]);
        }

        string memory trading = _readTradingFile();
        l.tradingRoleRegistry = stdJson.readAddress(trading, ".RoleRegistry");
        l.tradingDataProvider = stdJson.readAddress(trading, ".EtherFiDataProvider");
        // On OP the trading record points at the CASH Across/Enso proxies (they run on the cash stack)
        require(stdJson.readAddress(trading, ".AcrossSwapModule") == l.across, "OP trading Across != cash Across");
        require(stdJson.readAddress(trading, ".EnsoSwapModule") == l.enso, "OP trading Enso != cash Enso");
    }

    function _readEthLive() internal view returns (EthLive memory l) {
        require(block.chainid == 1, "not Ethereum");
        string memory cash = readDeploymentFile();
        l.roleRegistry = _cashAddr(cash, "RoleRegistry");
        l.stockUnwrapper = _cashAddr(cash, "StockUnwrapper");

        string memory trading = _readTradingFile();
        l.tradingRoleRegistry = stdJson.readAddress(trading, ".RoleRegistry");
        l.tradingDataProvider = stdJson.readAddress(trading, ".EtherFiDataProvider");
        l.tradingPriceProvider = stdJson.readAddress(trading, ".PriceProvider");
        l.across = stdJson.readAddress(trading, ".AcrossSwapModule");
        l.enso = stdJson.readAddress(trading, ".EnsoSwapModule");
        l.tradingLens = stdJson.readAddress(trading, ".TradingLens");
    }

    function _cashAddr(string memory json, string memory key) internal pure returns (address) {
        return stdJson.readAddress(json, string.concat(".addresses.", key));
    }

    function _readTradingFile() internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/deployments/mainnet/", vm.toString(block.chainid), "/trading-account.json"));
    }

    // ─────────────────────────────── deployment record + address derivation ───────────────────────────────

    function _recordPath() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/mainnet/", vm.toString(block.chainid), "/role-gating-batch3.json");
    }

    function _readRecord() internal view returns (string memory) {
        string memory path = _recordPath();
        require(vm.exists(path), "role-gating-batch3.json missing: run DeployRoleGatingBatch3 first");
        return vm.readFile(path);
    }

    /// @dev Chain-scoped salt: the same impl name carries different immutables on OP and ETH, so
    ///      the two must never share an address
    function _saltName(string memory name) internal view returns (string memory) {
        string memory tag = block.chainid == 10 ? "OP." : block.chainid == 1 ? "ETH." : "";
        require(bytes(tag).length > 0, "unsupported chain");
        return string.concat(SALT_PREFIX, tag, name);
    }

    function _predicted(string memory name) internal view returns (address) {
        return DEPLOYER.getDeterministicAddress(getSalt(_saltName(name)));
    }

    /// @dev Reads `key` from the record AND requires it equals the CREATE3 prediction for `saltName`,
    ///      so a hand-edited record cannot smuggle a foreign address into a bundle
    function _recorded(string memory record, string memory key, string memory saltName) internal view returns (address a) {
        a = stdJson.readAddress(record, string.concat(".", key));
        require(a == _predicted(saltName), string.concat("record != CREATE3 prediction: ", key));
        require(a.code.length > 0, string.concat("no code at recorded address: ", key));
    }

    // ─────────────────────────────── module config readers ───────────────────────────────

    /// @dev Constructor assets/tellers for a replacement liquid module: every candidate the live module has a teller for
    function _liquidConfig(EtherFiLiquidModule module) internal view returns (address[] memory assets, address[] memory tellers) {
        address[9] memory candidates = _liquidAssetCandidates();
        uint256 count;
        for (uint256 i = 0; i < candidates.length; ++i) {
            if (address(module.liquidAssetToTeller(candidates[i])) != address(0)) ++count;
        }
        require(count > 0, "liquid module has no configured assets");
        assets = new address[](count);
        tellers = new address[](count);
        uint256 j;
        for (uint256 i = 0; i < candidates.length; ++i) {
            address teller = address(module.liquidAssetToTeller(candidates[i]));
            if (teller != address(0)) {
                assets[j] = candidates[i];
                tellers[j] = teller;
                ++j;
            }
        }
    }

    function _midasConfig(MidasModule module) internal view returns (address[] memory tokens, address[] memory deposits, address[] memory redemptions) {
        address[3] memory candidates = _midasTokenCandidates();
        uint256 count;
        for (uint256 i = 0; i < candidates.length; ++i) {
            (address deposit,) = module.vaults(candidates[i]);
            if (deposit != address(0)) ++count;
        }
        require(count > 0, "Midas module has no configured vaults");
        tokens = new address[](count);
        deposits = new address[](count);
        redemptions = new address[](count);
        uint256 j;
        for (uint256 i = 0; i < candidates.length; ++i) {
            (address deposit, address redemption) = module.vaults(candidates[i]);
            if (deposit != address(0)) {
                tokens[j] = candidates[i];
                deposits[j] = deposit;
                redemptions[j] = redemption;
                ++j;
            }
        }
    }

    function _stargateConfig(StargateModule module) internal view returns (address[] memory assets, StargateModule.AssetConfig[] memory configs) {
        address[8] memory candidates = _stargateAssetCandidates();
        uint256 count;
        for (uint256 i = 0; i < candidates.length; ++i) {
            if (module.getAssetConfig(candidates[i]).pool != address(0)) ++count;
        }
        require(count > 0, "Stargate module has no configured assets");
        assets = new address[](count);
        configs = new StargateModule.AssetConfig[](count);
        uint256 j;
        for (uint256 i = 0; i < candidates.length; ++i) {
            StargateModule.AssetConfig memory c = module.getAssetConfig(candidates[i]);
            if (c.pool != address(0)) {
                assets[j] = candidates[i];
                configs[j] = c;
                ++j;
            }
        }
    }

    // ─────────────────────────────── small helpers ───────────────────────────────

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }

    function _contains(address[] memory list, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == needle) return true;
        }
        return false;
    }

    /// @dev True when `registry` already runs the re-gated RoleRegistry code (has the ADMIN_ROLE getter)
    function _registryIsRegated(address registry) internal view returns (bool) {
        (bool ok, bytes memory ret) = registry.staticcall(abi.encodeWithSignature("ADMIN_ROLE()"));
        return ok && ret.length == 32 && abi.decode(ret, (bytes32)) == ADMIN_ROLE;
    }
}
