// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";

/**
 * @title PaymentLinkConfig
 * @author ether.fi
 * @notice Shared configuration for the PaymentLinkModule deploy, verify and 3CP scripts on
 *         Optimism: env-prefixed CREATE3 salts (dev and prod land at distinct deterministic
 *         addresses through the EtherFiDeployer), the pinned addresses those salts resolve to,
 *         the prod governance addresses and the launch fee.
 * @dev The dev instance is a separate deployment on Optimism mainnet that registers only with
 *      the dev cash-v3 stack (deployments/dev/10). There are no testnet or fork environments.
 */
abstract contract PaymentLinkConfig is EtherFiDeployerHelper {
    using stdJson for string;

    // ---- CREATE3 salts (env-prefixed) ----

    string internal constant DEV_SALT_MODULE_IMPL = "Dev.PaymentLink.PaymentLinkModuleImpl";
    string internal constant DEV_SALT_MODULE_PROXY = "Dev.PaymentLink.PaymentLinkModuleProxy";
    string internal constant PROD_SALT_MODULE_IMPL = "Prod.PaymentLink.PaymentLinkModuleImpl";
    string internal constant PROD_SALT_MODULE_PROXY = "Prod.PaymentLink.PaymentLinkModuleProxy";

    // ---- Pinned addresses ----
    //
    // CREATE3 addresses are a pure function of the salt strings and the EtherFiDeployer address,
    // so pinning them turns a salt typo into a loud pre-broadcast failure instead of a deploy at
    // an address the backend, indexer and 3CP do not expect.

    /// @notice `Dev.PaymentLink.PaymentLinkModuleImpl` (Optimism).
    address internal constant EXPECTED_DEV_MODULE_IMPL = 0x0393014ce03Fe8F0EfeF0817D7c439474ff748dD;
    /// @notice `Dev.PaymentLink.PaymentLinkModuleProxy` (Optimism).
    address internal constant EXPECTED_DEV_MODULE_PROXY = 0x1bfCca1f03252D6734dCaB45F37AE3f81f6E0781;
    /// @notice `Prod.PaymentLink.PaymentLinkModuleImpl` (Optimism).
    address internal constant EXPECTED_PROD_MODULE_IMPL = 0x4d3B98947f10c36FE495110186fF854aB0F5593f;
    /// @notice `Prod.PaymentLink.PaymentLinkModuleProxy` (Optimism).
    address internal constant EXPECTED_PROD_MODULE_PROXY = 0x7402a988651bAF0558642647e0D7366D939d35c4;

    // ---- Prod governance (Optimism, deployments/mainnet/10/roles.json) ----

    /// @notice Prod Safe: proposer and executor on both timelocks, holds PAUSER and UNPAUSER.
    address internal constant PROD_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    /// @notice 8h operating timelock; the only holder of `ADMIN_TIMELOCK_ROLE` on Optimism.
    address internal constant OPERATING_TIMELOCK = 0x9AEb8eaa982084219d1A938D8F7B5040a1d47849;
    /// @notice `OPERATING_TIMELOCK.getMinDelay()`.
    uint256 internal constant OPERATING_TIMELOCK_DELAY = 8 hours;
    /// @notice 2-day upgrade timelock; owner of the prod RoleRegistry, so the module's upgrader.
    address internal constant UPGRADE_TIMELOCK = 0x9106cD76E10Ac60D1dd16144243416EbD2C64434;

    // ---- Fees ----

    /// @notice The proxy is initialised with the fee off: an unprivileged deployer key never
    ///         chooses the fee receiver. The enable step (3CP on prod) sets the launch fee.
    uint16 internal constant DEPLOY_FEE_BPS = 0;
    address internal constant DEPLOY_FEE_RECEIVER = address(0);

    /// @notice Launch fee on claims to non-safe recipients (spec §6 DEFAULT, PAY-1169).
    uint16 internal constant LAUNCH_FEE_BPS = 30;
    /// @notice Prod fee receiver. DEFAULT pending PAY-1169: the prod Safe, as for StockWithdrawModule.
    address internal constant PROD_FEE_RECEIVER = PROD_SAFE;

    // ---- Storage slots read by the verifiers ----

    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev UpgradeableProxy ERC-7201 slot; its first member is the roleRegistry (hijack check).
    bytes32 internal constant UPGRADEABLE_PROXY_STORAGE_SLOT = 0xa5586bb7fe6c4d1a576fc53fefe6d5915940638d338769f6905020734977f500;
    /// @dev OZ v5 Initializable ERC-7201 slot; the low 8 bytes are `_initialized`.
    bytes32 internal constant INITIALIZABLE_STORAGE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @dev Optimism chain id.
    uint256 internal constant OPTIMISM_CHAIN_ID = 10;

    // ---- Env-derived selectors ----

    /// @dev The target environment, from ENV (`dev` or `mainnet`, default `mainnet`). Virtual so
    ///      script tests can pick an environment without mutating the process-wide ENV variable.
    function _env() internal view virtual returns (string memory) {
        return getEnv();
    }

    /// @dev True when the target is dev; picks salts, the deployments file and the privileged-call path.
    function _isDev() internal view returns (bool) {
        return isEqualString(_env(), "dev");
    }

    function _moduleImplSalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_MODULE_IMPL : PROD_SALT_MODULE_IMPL;
    }

    function _moduleProxySalt() internal view returns (string memory) {
        return _isDev() ? DEV_SALT_MODULE_PROXY : PROD_SALT_MODULE_PROXY;
    }

    function _expectedImpl() internal view returns (address) {
        return _isDev() ? EXPECTED_DEV_MODULE_IMPL : EXPECTED_PROD_MODULE_IMPL;
    }

    function _expectedProxy() internal view returns (address) {
        return _isDev() ? EXPECTED_DEV_MODULE_PROXY : EXPECTED_PROD_MODULE_PROXY;
    }

    /// @dev The fee receiver the enable step sets: the dev admin on dev, `PROD_FEE_RECEIVER` on prod.
    function _feeReceiverFor(address devAdmin) internal view returns (address) {
        return _isDev() ? devAdmin : PROD_FEE_RECEIVER;
    }

    // ---- Stack addresses ----

    struct Stack {
        EtherFiDataProvider dataProvider;
        RoleRegistry roleRegistry;
        ICashModule cashModule;
    }

    /// @dev Reads the cash-v3 stack for `env` from deployments/{env}/10/deployments.json,
    ///      independently of the ENV variable (so dev scripts can also read prod).
    function _stack(string memory env) internal view returns (Stack memory s) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/", env, "/10/deployments.json"));
        s.dataProvider = EtherFiDataProvider(json.readAddress(".addresses.EtherFiDataProvider"));
        s.roleRegistry = RoleRegistry(json.readAddress(".addresses.RoleRegistry"));
        s.cashModule = ICashModule(json.readAddress(".addresses.CashModule"));
    }

    /// @dev The stack the current environment targets.
    function _currentStack() internal view returns (Stack memory) {
        return _stack(_env());
    }

    // ---- Guards ----

    /// @dev Both envs' salts must resolve to the pinned addresses, and dev must never alias prod.
    function _assertPinnedAddresses() internal view {
        require(_predictAddress(DEV_SALT_MODULE_IMPL) == EXPECTED_DEV_MODULE_IMPL, "dev impl salt does not resolve to the pinned address");
        require(_predictAddress(DEV_SALT_MODULE_PROXY) == EXPECTED_DEV_MODULE_PROXY, "dev proxy salt does not resolve to the pinned address");
        require(_predictAddress(PROD_SALT_MODULE_IMPL) == EXPECTED_PROD_MODULE_IMPL, "prod impl salt does not resolve to the pinned address");
        require(_predictAddress(PROD_SALT_MODULE_PROXY) == EXPECTED_PROD_MODULE_PROXY, "prod proxy salt does not resolve to the pinned address");
    }

    /// @dev The stack is internally consistent: the module is built against exactly this
    ///      DataProvider, its CashModule and its RoleRegistry. On dev it must not be the prod stack.
    function _assertStack(Stack memory s) internal view {
        require(address(s.dataProvider).code.length > 0, "DataProvider has no code");
        require(s.dataProvider.getCashModule() == address(s.cashModule), "DataProvider.getCashModule() != deployments CashModule");
        require(address(s.dataProvider.roleRegistry()) == address(s.roleRegistry), "DataProvider.roleRegistry() != deployments RoleRegistry");
        if (_isDev()) {
            Stack memory prod = _stack("mainnet");
            require(address(s.dataProvider) != address(prod.dataProvider), "dev stack resolves to the prod DataProvider");
            require(address(s.cashModule) != address(prod.cashModule), "dev stack resolves to the prod CashModule");
            require(address(s.roleRegistry) != address(prod.roleRegistry), "dev stack resolves to the prod RoleRegistry");
        }
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }

    function _registryOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, UPGRADEABLE_PROXY_STORAGE_SLOT))));
    }

    function _initializedVersion(address target) internal view returns (uint64) {
        return uint64(uint256(vm.load(target, INITIALIZABLE_STORAGE_SLOT)));
    }

    function _canRequestWithdraw(ICashModule cashModule, address module) internal view returns (bool) {
        address[] memory allowed = cashModule.getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < allowed.length; i++) {
            if (allowed[i] == module) return true;
        }
        return false;
    }
}
