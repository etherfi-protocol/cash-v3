// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { UUPSProxy } from "../../src/UUPSProxy.sol";
import { EtherFiDataProvider } from "../../src/data-provider/EtherFiDataProvider.sol";
import { ICashModule } from "../../src/interfaces/ICashModule.sol";
import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";
import { RoleRegistry } from "../../src/role-registry/RoleRegistry.sol";
import { EtherFiDeployer } from "../../src/utils/EtherFiDeployer.sol";
import { ContractCodeChecker } from "../utils/ContractCodeChecker.sol";
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
abstract contract PaymentLinkConfig is EtherFiDeployerHelper, ContractCodeChecker {
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

    // ---- Token allowlist ----

    /// @notice USDC (Optimism), the only launch token. Further tokens are allowed later through
    ///         another timelocked `setTokenAllowed`, and only if they transfer exact amounts.
    address internal constant LAUNCH_TOKEN_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;

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

    /**
     * @dev PLM-04: what sits at the pinned addresses must be exactly what this commit builds and
     *      deploys. A CREATE3 address commits to neither bytecode nor constructor state, so:
     *      - the impl's immutables must be THIS stack's DataProvider and CashModule (checked by
     *        getter: the code comparison alone would accept other addresses whose code matches,
     *        such as another stack's proxies);
     *      - the impl must match a local build except its embedded own address (UUPS `__self`),
     *        and the proxy must match a local `UUPSProxy` exactly and point at that impl;
     *      - the impl's `proxiableUUID()` must answer when called directly, which proves its
     *        embedded `__self` is its own address (the code comparison would accept a `__self`
     *        that happens to equal the local reference's address);
     *      - the proxy must have run its initializer exactly once and the impl's initializers
     *        must be disabled (`_requireInitialized`), so nobody can initialize it later.
     *      Runtime code and these slots cannot prove the rest of the proxy's storage is empty: a
     *      custom constructor could seed links. The enable 3CP therefore also checks the proxy's
     *      deployment transaction (`_requireProxyProvenance`).
     */
    function _requireBuiltCode(Stack memory s, address impl, address proxy) internal {
        PaymentLinkModule deployed = PaymentLinkModule(impl);
        require(address(deployed.etherFiDataProvider()) == address(s.dataProvider), "PaymentLinkModule impl: etherFiDataProvider immutable is not this stack's");
        require(address(deployed.cashModule()) == address(s.cashModule), "PaymentLinkModule impl: cashModule immutable is not this stack's");

        address localImpl = address(new PaymentLinkModule(address(s.dataProvider), address(s.cashModule)));
        requireCodeMatchAllowingAddressEmbeds("PaymentLinkModuleImpl", impl, localImpl);
        requireExactCodeMatch("PaymentLinkModuleProxy", proxy, address(new UUPSProxy(localImpl, "")));
        require(_implOf(proxy) == impl, "PaymentLinkModule: proxy impl slot does not point at the verified impl - possible hijack");
        try UUPSUpgradeable(impl).proxiableUUID() returns (bytes32 slot) {
            require(slot == EIP1967_IMPL_SLOT, "PaymentLinkModule impl: unexpected proxiableUUID");
        } catch {
            revert("PaymentLinkModule impl: proxiableUUID reverts when called directly - embedded __self is not the impl address");
        }
        _requireInitialized(impl, proxy);
    }

    /// @dev The proxy initcode the deploy script sends to the EtherFiDeployer: `UUPSProxy` with
    ///      `impl` and the atomic `initialize(roleRegistry, 0, address(0))` call. The 3CP's
    ///      provenance check compares against the same bytes.
    function _expectedProxyInitCode(Stack memory s, address impl) internal pure returns (bytes memory) {
        bytes memory initData = abi.encodeCall(PaymentLinkModule.initialize, (address(s.roleRegistry), DEPLOY_FEE_BPS, DEPLOY_FEE_RECEIVER));
        return abi.encodePacked(type(UUPSProxy).creationCode, abi.encode(impl, initData));
    }

    // ---- Deployment provenance (PLM-04) ----

    /// @dev What `_requireProxyProvenance` needs from a transaction.
    struct DeployTx {
        address to;
        bytes input;
        bool success;
        bytes32 blockHash;
        uint256 blockNumber;
    }

    /**
     * @dev Requires `txHash` to be a successful direct call to `EtherFiDeployer.deploy` with the
     *      proxy salt and exactly `_expectedProxyInitCode`, mined in a finalized block that is an
     *      ancestor of the state under review. `deploy` reverts when the CREATE3 address is
     *      occupied, so such a call proves this initcode created the proxy and that its storage is
     *      only what `UUPSProxy`'s constructor and `initialize` wrote, not something a custom
     *      constructor seeded. See `_requireCanonicalOnReviewedChain` for the chain binding.
     */
    function _requireProxyProvenance(Stack memory s, address impl, string memory proxySalt, bytes32 txHash) internal {
        require(txHash != bytes32(0), "proxy deploy tx hash not provided (set PAYMENT_LINK_PROXY_DEPLOY_TX)");
        DeployTx memory t = _fetchTx(txHash);
        require(t.success, "proxy deploy tx did not succeed");
        require(t.to == address(DEPLOYER), "proxy deploy tx was not a direct call to the EtherFiDeployer");
        bytes memory expected = abi.encodeCall(EtherFiDeployer.deploy, (getSalt(proxySalt), _expectedProxyInitCode(s, impl)));
        require(keccak256(t.input) == keccak256(expected), "proxy deploy tx is not the expected EtherFiDeployer.deploy call - proxy storage unverified");
        _requireCanonicalOnReviewedChain(t.blockHash, t.blockNumber);
    }

    /**
     * @dev Binds a block to the history of the state this script reviews. The transaction comes
     *      from the provenance endpoint, and the fork only exposes `blockhash` for its last 256
     *      blocks, so the endpoint is anchored to the fork first:
     *      1. the endpoint's canonical hash at the fork's parent height equals the fork's own
     *         `blockhash` there, so both follow the same chain and branch;
     *      2. the endpoint's canonical hash at `blockNumber` equals `blockHash`, so the block was
     *         not reorged out (a block the node merely knows, on an abandoned branch, fails);
     *      3. `blockNumber` is below the fork's head (an ancestor of the reviewed state) and at or
     *         below the endpoint's finalized head, so it cannot be reorged out later.
     *      The endpoint is trusted not to fabricate answers; this guards against pointing it at
     *      another chain, another fork or a reorged branch.
     */
    function _requireCanonicalOnReviewedChain(bytes32 blockHash, uint256 blockNumber) internal {
        require(block.number > 1 && blockNumber < block.number - 1, "proxy deploy tx's block is not before the state under review");
        bytes32 forkParent = blockhash(block.number - 1);
        require(forkParent != bytes32(0) && _castBlockHash(vm.toString(block.number - 1)) == forkParent, "provenance RPC does not follow the chain under review");
        require(_castBlockHash(vm.toString(blockNumber)) == blockHash, "proxy deploy tx's block is not canonical on the chain under review");
        require(blockNumber <= _castDecimal(_castArgs3("block", "finalized", "--field", "number")), "proxy deploy tx's block is not finalized yet");
    }

    /// @dev Reads a transaction's recipient, calldata, status and block from Optimism through
    ///      `cast` (ffi, enabled in foundry.toml). Virtual for script tests.
    function _fetchTx(bytes32 txHash) internal virtual returns (DeployTx memory t) {
        string memory hash = vm.toString(txHash);
        bytes memory to = _castArgs3("tx", hash, "to", "");
        require(to.length == 20, "could not read the deploy tx recipient");
        t.to = address(bytes20(to));
        t.input = _castArgs3("tx", hash, "input", "");
        bytes32 status = keccak256(_castArgs3("receipt", hash, "status", ""));
        t.success = status == keccak256("true") || status == keccak256("1") || status == keccak256("0x1") || status == keccak256(hex"01");
        bytes memory blockHash = _castArgs3("receipt", hash, "blockHash", "");
        require(blockHash.length == 32, "could not read the deploy tx block hash");
        t.blockHash = bytes32(blockHash);
        t.blockNumber = _castDecimal(_castArgs3("receipt", hash, "blockNumber", ""));
    }

    /// @dev RPC for the provenance reads: PAYMENT_LINK_PROVENANCE_RPC, else OPTIMISM_RPC, else the
    ///      public endpoint (an empty variable counts as unset). Virtual for script tests.
    function _provenanceRpc() internal view virtual returns (string memory) {
        string memory rpc = vm.envOr("PAYMENT_LINK_PROVENANCE_RPC", string(""));
        if (bytes(rpc).length == 0) rpc = vm.envOr("OPTIMISM_RPC", string(""));
        if (bytes(rpc).length == 0) rpc = "https://mainnet.optimism.io";
        return rpc;
    }

    function _castBlockHash(string memory blockNumber) internal returns (bytes32) {
        bytes memory h = _castArgs3("block", blockNumber, "--field", "hash");
        require(h.length == 32, "could not read a block hash from the provenance RPC");
        return bytes32(h);
    }

    /// @dev `cast <a> <b> <c> [<d>] --rpc-url <provenance RPC>` through ffi; empty `d` is omitted.
    function _castArgs3(string memory a, string memory b, string memory c, string memory d) internal returns (bytes memory) {
        bool withD = bytes(d).length > 0;
        string[] memory cmd = new string[](withD ? 7 : 6);
        cmd[0] = "cast";
        cmd[1] = a;
        cmd[2] = b;
        cmd[3] = c;
        uint256 i = 4;
        if (withD) cmd[i++] = d;
        cmd[i++] = "--rpc-url";
        cmd[i] = _provenanceRpc();
        return vm.ffi(cmd);
    }

    /// @dev Parses a decimal number printed by `cast`. ffi hex-decodes output that looks like hex,
    ///      which an even-length run of digits does; re-printing those bytes as hex restores them.
    function _castDecimal(bytes memory out) internal pure returns (uint256) {
        bool digits = out.length > 0;
        for (uint256 i = 0; i < out.length && digits; i++) {
            digits = out[i] >= "0" && out[i] <= "9";
        }
        if (digits) return vm.parseUint(string(out));
        string memory asHex = vm.toString(out); // "0x" + the original digits
        bytes memory stripped = new bytes(bytes(asHex).length - 2);
        for (uint256 i = 0; i < stripped.length; i++) {
            stripped[i] = bytes(asHex)[i + 2];
        }
        return vm.parseUint(string(stripped));
    }

    /// @dev The whole OZ Initializable slot, not just the version: the proxy is at version 1 and
    ///      not mid-initialization; the impl is locked at `type(uint64).max`.
    function _requireInitialized(address impl, address proxy) internal view {
        require(uint256(vm.load(proxy, INITIALIZABLE_STORAGE_SLOT)) == 1, "proxy not initialised exactly once");
        require(uint256(vm.load(impl, INITIALIZABLE_STORAGE_SLOT)) == uint256(type(uint64).max), "impl initializers not disabled");
    }

    function _implOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPL_SLOT))));
    }

    function _registryOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, UPGRADEABLE_PROXY_STORAGE_SLOT))));
    }

    function _canRequestWithdraw(ICashModule cashModule, address module) internal view returns (bool) {
        address[] memory allowed = cashModule.getWhitelistedModulesCanRequestWithdraw();
        for (uint256 i = 0; i < allowed.length; i++) {
            if (allowed[i] == module) return true;
        }
        return false;
    }
}
