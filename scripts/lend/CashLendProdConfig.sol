// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { CREATE3 } from "solady/utils/CREATE3.sol";

/**
 * @title CashLendProdConfig
 * @notice Single source of truth for the constants and address derivation shared by
 *         DeployCashLendProd and VerifyCashLendProd. Both inherit this, so neither can drift from
 *         the other: the verifier's core hijack check is "the impl slot holds the address I predict",
 *         which proves nothing if the two scripts predict addresses differently.
 *
 * @dev No cheatcode use here — inheriting `vm` from forge-std in a second base would collide, so
 *      anything needing vm (json reads, storage-slot loads) stays in the scripts themselves.
 */
abstract contract CashLendProdConfig {
    // ─────────────────────────────── protocol infrastructure ───────────────────────────────

    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev roleRegistry slot of UpgradeableProxy's ERC-7201 namespaced storage (hijack detection).
    bytes32 internal constant UPGRADEABLE_PROXY_ROLE_REGISTRY_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;

    /// @dev The prod Cash Safe; owns RoleRegistry and executes the generated Gnosis bundle.
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /**
     * @dev Protocol-owned PERMISSIONED CREATE3 deployer, mirroring
     *      deployments/deployer/etherfi-deployer.json (asserted at runtime by both scripts).
     *
     *      This must never become a public factory such as Nick's. CREATE3 through a public factory
     *      derives the address from the salt alone and its intermediate proxy accepts a call from
     *      anybody, so — our salts being published in this repo — anyone could occupy every
     *      `CashLendProd.*` address with bytecode of their choosing before we broadcast. The deploy
     *      script's skip-if-code-exists branch would then feed that foreign address into the Safe
     *      bundle as an implementation, and the verifier would happily confirm it. Deploying through
     *      a registry-gated deployer is what makes "code is already here" mean "we put it there".
     */
    address internal constant ETHERFI_DEPLOYER = 0xFCD957b5913d607BF2222280093421B1e2Af6f30;

    string internal constant DEPLOYER_RECORD_PATH = "/deployments/deployer/etherfi-deployer.json";

    /// @dev Namespace for every salt this upgrade derives. Bump only to intentionally move the whole
    ///      address family to fresh addresses.
    string internal constant SALT_PREFIX = "CashLendProd.";

    // ─────────────────────────────── gateway configuration ───────────────────────────────

    /**
     * @dev Post-op health-factor floor for user-extraction ops. NOTE: 0 is a valid value on
     *      LendGateway and DISABLES enforcement (ensureMinHealthFactor no-ops), so both scripts
     *      assert this exact value rather than merely "non-zero".
     */
    uint256 internal constant MIN_HEALTH_FACTOR = 1.05e18;

    // ─────────────────────────────── liquid assets ───────────────────────────────

    // Candidate liquid assets on Optimism. Constructor tellers and withdraw queues are copied for
    // whichever of these the live module has configured, so dev/prod drift is absorbed here — a
    // NEW asset listed on prod after this script was written must be appended before running.
    address internal constant LIQUID_ETH = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
    address internal constant LIQUID_USD = 0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C;
    address internal constant LIQUID_BTC = 0x5f46d540b6eD704C3c8789105F30E075AA900726;
    address internal constant EBTC = 0x657e8C867D8B37dCC18fA4Caead9C45EB088C642;
    address internal constant SETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    address internal constant EUSD = 0x939778D83b46B456224A33Fb59630B11DEC56663;
    address internal constant LIQUID_RESERVE = 0xca5921DF65E2e1b0B98Ae91c0187BA80D4124898;
    address internal constant LIQUID_EUR = 0xcC476B1a49bcDf5192561e87b6Fb8ea78aa28C13;
    address internal constant LIQUID_RWA = 0x17bC8Ffd82b8a36e737Ca1141C025089589B915e;

    function _liquidAssetCandidates() internal pure returns (address[9] memory) {
        return [LIQUID_ETH, LIQUID_USD, LIQUID_BTC, EBTC, SETHFI, EUSD, LIQUID_RESERVE, LIQUID_EUR, LIQUID_RWA];
    }

    // ─────────────────────────────── spend assets ───────────────────────────────

    /// @dev fixtures.json keys of every asset the bundle registers as a gateway spend asset. Both
    ///      scripts read this list back, so a dropped setSpendAsset tx fails rather than ships.
    function _spendAssetKeys() internal pure returns (string[7] memory) {
        return ["usdc", "usdt", "eurc", "liquidUsd", "liquidReserve", "liquidEUR", "fraxusd"];
    }

    // ─────────────────────────────── replacement modules ───────────────────────────────

    /// @dev Canonical module order, shared by the deploy script's `Deployed.modules` / `Policy`
    ///      arrays and the verifier's per-module checks. Index-aligned with _oldModuleKeys.
    function _moduleSaltNames() internal pure returns (string[7] memory) {
        return ["OpenOceanModule", "LiquidModule", "LiquidReferrerModule", "FraxModule", "StakeModule", "MidasModule", "BeHYPEModule"];
    }

    /// @dev deployments.json `.addresses.*` keys of the live modules being replaced.
    function _oldModuleKeys() internal pure returns (string[7] memory) {
        return [
            "OpenOceanSwapModule",
            "EtherFiLiquidModule",
            "EtherFiLiquidModuleWithReferrer",
            "FraxModule",
            "EtherFiStakeModule",
            "MidasModule",
            "BeHYPEStakeModule"
        ];
    }

    // ─────────────────────────────── address derivation ───────────────────────────────

    function _salt(string memory name) internal pure returns (bytes32) {
        return keccak256(bytes(string.concat(SALT_PREFIX, name)));
    }

    /// @dev The address `EtherFiDeployer.deploy(_salt(name), ...)` produces.
    function _predicted(string memory name) internal pure returns (address) {
        return CREATE3.predictDeterministicAddress(_salt(name), ETHERFI_DEPLOYER);
    }
}
