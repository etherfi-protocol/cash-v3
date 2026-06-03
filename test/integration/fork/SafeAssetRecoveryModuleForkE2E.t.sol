// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { SafeAssetRecoveryModule } from "../../../src/modules/recovery/SafeAssetRecoveryModule.sol";
import { ISafeAssetRecoveryModule } from "../../../src/interfaces/ISafeAssetRecoveryModule.sol";
import { IRoleRegistry } from "../../../src/interfaces/IRoleRegistry.sol";
import { EtherFiDataProvider } from "../../../src/data-provider/EtherFiDataProvider.sol";
import { EtherFiSafe } from "../../../src/safe/EtherFiSafe.sol";
import { EtherFiSafeFactory } from "../../../src/safe/EtherFiSafeFactory.sol";
import { MockERC20 } from "../../../src/mocks/MockERC20.sol";

/**
 * @notice End-to-end recovery against the **production** Optimism deployment, forked from OP mainnet.
 *         Uses the real prod EtherFiDataProvider / RoleRegistry / EtherFiSafeFactory. A fresh safe is
 *         deployed through the real factory with an owner key the test controls, so the genuine
 *         owner-quorum signature path is exercised with no storage overrides.
 *
 * Flow (every transaction the prod rollout will run):
 *   deploy a safe via the prod factory → deploy the module → whitelist it in the prod DataProvider →
 *   enable it on the safe (owner-signed) → fund the safe with an unsupported ERC20 → recover.
 *
 * Env: OPTIMISM_RPC (defaults to a public OP RPC), FORK_BLOCK (0 / unset = latest).
 *
 * Run: OPTIMISM_RPC=<archive or public OP rpc> forge test --match-contract SafeAssetRecoveryModuleForkE2E -vvv
 */
contract SafeAssetRecoveryModuleForkE2E is Test {
    // Production Optimism deployment (deployments/mainnet/10).
    address constant DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
    address constant ROLE_REGISTRY = 0x5C1E3D653fcbC54Ae25c2AD9d59548D2082C687B;
    address constant SAFE_FACTORY  = 0xF4e147Db314947fC1275a8CbB6Cde48c510cd8CF;

    SafeAssetRecoveryModule module;
    EtherFiSafe safe;
    uint256 ownerPk;
    address ownerAddr;
    address recipient;

    function setUp() public {
        string memory rpc = vm.envOr("OPTIMISM_RPC", string("https://optimism-rpc.publicnode.com"));
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        require(DATA_PROVIDER.code.length > 0, "fork is not on Optimism mainnet (prod DataProvider missing)");

        (ownerAddr, ownerPk) = makeAddrAndKey("safeOwner");
        recipient = makeAddr("recoveryRecipient");

        // Grant ourselves the factory admin role (via the prod RoleRegistry owner) so we can deploy a
        // safe — mirrors how ether.fi's deployer is authorized in prod.
        EtherFiSafeFactory factory = EtherFiSafeFactory(SAFE_FACTORY);
        IRoleRegistry rr = IRoleRegistry(ROLE_REGISTRY);
        bytes32 factoryRole = factory.ETHERFI_SAFE_FACTORY_ADMIN_ROLE();
        address rrOwner = rr.owner();
        vm.prank(rrOwner);
        rr.grantRole(factoryRole, address(this));

        // Deploy a fresh safe through the real prod factory, owned by our test key (threshold 1).
        address[] memory owners = new address[](1);
        owners[0] = ownerAddr;
        address[] memory mods = new address[](0);
        bytes[] memory setup = new bytes[](0);
        bytes32 salt = keccak256("SafeAssetRecoveryModule.fork.e2e.v1");
        factory.deployEtherFiSafe(salt, owners, mods, setup, 1);
        safe = EtherFiSafe(payable(factory.getDeterministicAddress(salt)));
    }

    function test_e2e_recoverUnsupportedToken() public {
        assertTrue(EtherFiDataProvider(DATA_PROVIDER).isEtherFiSafe(address(safe)), "safe not registered in prod DataProvider");

        // A fresh mock ERC20 is, by construction, neither cash collateral nor a borrow token.
        MockERC20 token = new MockERC20("Stuck", "STUCK", 18);
        uint256 amount = 1_000e18;
        token.mint(address(safe), amount);

        // 1. Deploy the module against the prod DataProvider.
        module = new SafeAssetRecoveryModule(DATA_PROVIDER);

        // 2. Whitelist it in the prod DataProvider (grant ourselves the admin role via the RR owner;
        //    on prod this single call is the operating-safe 3CP).
        _whitelistModule();
        assertTrue(EtherFiDataProvider(DATA_PROVIDER).isWhitelistedModule(address(module)), "not whitelisted");

        // 3. Enable the module on the safe (owner-quorum configureModules, real signature).
        _enableModuleOnSafe();
        assertTrue(module.getNonce(address(safe)) == 0, "sanity: module nonce unused before recover");

        // 4. Recover: owner signs, anyone submits.
        (address[] memory signers, bytes[] memory sigs) = _signRecover(address(token), recipient);
        vm.expectEmit(true, true, true, true, address(module));
        emit ISafeAssetRecoveryModule.AssetRecovered(address(safe), address(token), recipient, amount);
        module.recover(address(safe), address(token), recipient, signers, sigs);

        // 5. Assert the sweep landed with the recipient and drained the safe.
        assertEq(token.balanceOf(recipient), amount, "recipient did not receive full balance");
        assertEq(token.balanceOf(address(safe)), 0, "safe still holds the token");
        console.log("recovered %s to %s", amount, recipient);
    }

    // --- helpers ---

    function _whitelistModule() internal {
        EtherFiDataProvider dp = EtherFiDataProvider(DATA_PROVIDER);
        IRoleRegistry rr = IRoleRegistry(ROLE_REGISTRY);
        bytes32 role = dp.DATA_PROVIDER_ADMIN_ROLE();
        vm.prank(rr.owner());
        rr.grantRole(role, address(this));

        address[] memory mods = new address[](1);
        mods[0] = address(module);
        bool[] memory wl = new bool[](1);
        wl[0] = true;
        dp.configureModules(mods, wl);
    }

    function _enableModuleOnSafe() internal {
        address[] memory mods = new address[](1);
        mods[0] = address(module);
        bool[] memory wl = new bool[](1);
        wl[0] = true;
        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";

        bytes32[] memory dataHashes = new bytes32[](1);
        dataHashes[0] = keccak256(setupData[0]);
        bytes32 setupDataHash = keccak256(abi.encodePacked(dataHashes));

        bytes32 structHash = keccak256(abi.encode(
            safe.CONFIGURE_MODULES_TYPEHASH(),
            keccak256(abi.encodePacked(mods)),
            keccak256(abi.encodePacked(wl)),
            setupDataHash,
            safe.nonce()
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", safe.getDomainSeparator(), structHash));

        (address[] memory signers, bytes[] memory sigs) = _sign(digest);
        safe.configureModules(mods, wl, setupData, signers, sigs);
    }

    function _signRecover(address token_, address recipient_)
        internal
        view
        returns (address[] memory signers, bytes[] memory sigs)
    {
        bytes32 digest = keccak256(abi.encode(
            block.chainid,
            address(module),
            module.getNonce(address(safe)),
            address(safe),
            token_,
            recipient_
        ));
        return _sign(digest);
    }

    function _sign(bytes32 digest) internal view returns (address[] memory signers, bytes[] memory sigs) {
        signers = new address[](1);
        signers[0] = ownerAddr;
        sigs = new bytes[](1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        sigs[0] = abi.encodePacked(r, s, v);
    }
}
