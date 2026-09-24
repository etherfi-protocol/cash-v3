// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { StargateModule } from "../../src/modules/stargate/StargateModule.sol";
import { Utils } from "../utils/Utils.sol";
import { Usdt0SupportProd as C } from "./Usdt0SupportProdConfig.sol";

interface ISettlementDispatcherLike {
    function setSettlementRecipients(address[] calldata tokens, address[] calldata recipients) external;
    function getSettlementRecipient(address token) external view returns (address);
}

interface ILendGatewayLike {
    function reserveIdOf(address asset) external view returns (uint256);
    function isRegistered(address asset) external view returns (bool);
    function isSpendAsset(address asset) external view returns (bool);
}

interface IOAppPeers {
    function peers(uint32 eid) external view returns (bytes32);
}

interface IOftLike {
    function token() external view returns (address);
    function approvalRequired() external view returns (bool);
}

/**
 * @title ConfigureUsdt0SupportDev
 * @notice The dev counterpart of 3CP-699 — the settlement and cross-chain-withdrawal legs of USD₮0
 *         support, on the dev cash deployment on Optimism.
 *
 *         It is two calls, not three, and it is an EOA broadcast rather than a Safe bundle, because
 *         dev differs from prod in two ways worth stating:
 *
 *         1. NO TIMELOCK. `ADMIN_ROLE` and `ADMIN_TIMELOCK_ROLE` have no holders on the dev
 *            RoleRegistry — the cash-v3#289 re-gating that reached prod has not reached dev — so the
 *            dev dispatchers still check `onlyRoleRegistryOwner`, and the owner is the deployer EOA.
 *            699's schedule/execute pair has no dev equivalent.
 *         2. THE LEND GATEWAY LEG IS ALREADY LIVE. USD₮0 is already a registered dev gateway reserve
 *            and already a spend asset, so 699's third transaction has nothing to do here. This
 *            script asserts that rather than repeating it, and prints the dev reserve id, which is
 *            NOT prod's 23 — dev listed different assets in a different order.
 *
 *         Also unlike prod, every dev dispatcher settles USDT, CardOrder included, so all four get a
 *         recipient. The list is derived from each dispatcher's live `getSettlementRecipient(USDT)`
 *         rather than hardcoded, which is the same mirroring rule 699 uses and is what makes the two
 *         scripts agree without sharing a recipient table.
 *
 * Usage (simulate by dropping --broadcast; the wallet must be the dev RoleRegistry owner and hold
 * STARGATE_MODULE_ADMIN_ROLE):
 *   source .env && ENV=dev forge script \
 *     scripts/usdt0-support/ConfigureUsdt0SupportDev.s.sol:ConfigureUsdt0SupportDev \
 *     --rpc-url $OPTIMISM_RPC --broadcast -vvvv
 *
 * Read-only re-check of the end state:
 *   ENV=dev forge script scripts/usdt0-support/ConfigureUsdt0SupportDev.s.sol:ConfigureUsdt0SupportDev \
 *     --sig 'verify()' --rpc-url $OPTIMISM_RPC
 */
contract ConfigureUsdt0SupportDev is Utils {
    /// @dev The dev dispatchers, in `BinSponsor` order, as named in the dev deployment file
    string[4] internal DISPATCHER_KEYS = [
        "SettlementDispatcherReap",
        "SettlementDispatcherRain",
        "SettlementDispatcherPix",
        "SettlementDispatcherCardOrder"
    ];

    function run() public {
        _requireDevOptimism();

        address[] memory dispatchers = _dispatchers();
        StargateModule stargateModule = StargateModule(payable(_devAddress(".addresses.StargateModule")));
        IRoleRegistry roleRegistry = IRoleRegistry(_devAddress(".addresses.RoleRegistry"));

        address sender = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(sender == roleRegistry.owner(), "sender is not the dev RoleRegistry owner (setSettlementRecipients is owner-gated on dev)");
        require(roleRegistry.hasRole(stargateModule.STARGATE_MODULE_ADMIN_ROLE(), sender), "sender lacks STARGATE_MODULE_ADMIN_ROLE");

        address[] memory recipients = _usdtRecipients(dispatchers);
        _requireOft();

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // 1. USDT0 settles where USDT settles, per dispatcher
        for (uint256 i; i < dispatchers.length; ++i) {
            address[] memory tokens = new address[](1);
            address[] memory to = new address[](1);
            tokens[0] = C.USDT0;
            to[0] = recipients[i];
            ISettlementDispatcherLike(dispatchers[i]).setSettlementRecipients(tokens, to);
        }

        // 2. USDT0 as an OFT on the StargateModule — opens Ethereum / Arbitrum / HyperEVM at once,
        //    since destEid is a requestBridge argument rather than configuration
        {
            address[] memory assets = new address[](1);
            assets[0] = C.USDT0;
            StargateModule.AssetConfig[] memory configs = new StargateModule.AssetConfig[](1);
            configs[0] = StargateModule.AssetConfig({ isOFT: true, pool: C.USDT0_OFT_OP });
            stargateModule.setAssetConfig(assets, configs);
        }

        vm.stopBroadcast();

        _verify();
    }

    /// @dev Fork-only, and needs no key: the same two calls pranked as the dev RoleRegistry owner,
    ///      then the same verification. Run this before broadcasting — it is the only way to prove
    ///      the calls land without holding the dev deployer key.
    function rehearse() public {
        _requireDevOptimism();

        address[] memory dispatchers = _dispatchers();
        StargateModule stargateModule = StargateModule(payable(_devAddress(".addresses.StargateModule")));
        address owner = IRoleRegistry(_devAddress(".addresses.RoleRegistry")).owner();

        address[] memory recipients = _usdtRecipients(dispatchers);
        _requireOft();

        vm.startPrank(owner);
        for (uint256 i; i < dispatchers.length; ++i) {
            address[] memory tokens = new address[](1);
            address[] memory to = new address[](1);
            tokens[0] = C.USDT0;
            to[0] = recipients[i];
            ISettlementDispatcherLike(dispatchers[i]).setSettlementRecipients(tokens, to);
        }
        {
            address[] memory assets = new address[](1);
            assets[0] = C.USDT0;
            StargateModule.AssetConfig[] memory configs = new StargateModule.AssetConfig[](1);
            configs[0] = StargateModule.AssetConfig({ isOFT: true, pool: C.USDT0_OFT_OP });
            stargateModule.setAssetConfig(assets, configs);
        }
        vm.stopPrank();

        console.log("[REHEARSAL] pranked as the dev RoleRegistry owner %s", owner);
        _verify();
    }

    /// @dev Read-only. Safe to run before the broadcast too — it will simply fail on what is not set.
    function verify() public view {
        _requireDevOptimism();
        _verify();
    }

    function _verify() internal view {
        address[] memory dispatchers = _dispatchers();
        StargateModule stargateModule = StargateModule(payable(_devAddress(".addresses.StargateModule")));
        ILendGatewayLike gateway = ILendGatewayLike(
            stdJson.readAddress(
                vm.readFile(string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(block.chainid), "/cash-lend.json")),
                ".lendGateway"
            )
        );

        for (uint256 i; i < dispatchers.length; ++i) {
            address usdt0Recipient = ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(C.USDT0);
            address usdtRecipient = ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(C.USDT);
            require(usdt0Recipient != address(0), string.concat(DISPATCHER_KEYS[i], ": USDT0 recipient not set"));
            require(usdt0Recipient == usdtRecipient, string.concat(DISPATCHER_KEYS[i], ": USDT0 recipient != USDT recipient"));
            console.log("  %s USDT0 -> %s", DISPATCHER_KEYS[i], usdt0Recipient);
        }

        StargateModule.AssetConfig memory config = stargateModule.getAssetConfig(C.USDT0);
        require(config.isOFT, "USDT0 not marked as an OFT");
        require(config.pool == C.USDT0_OFT_OP, "USDT0 pool is not the OP USD0 OFT");

        // Already live on dev; asserted rather than written, so a dev rollback shows up here
        require(gateway.isRegistered(C.USDT0), "USDT0 is not a dev lend-gateway reserve");
        require(gateway.isSpendAsset(C.USDT0), "USDT0 is not a dev lend-gateway spend asset");
        console.log("  LendGateway: USDT0 already reserve %s, spend asset", gateway.reserveIdOf(C.USDT0));

        console.log("Withdrawal quotes (native fee, wei) for 1000 USDT0:");
        _logQuote(stargateModule, "Ethereum (delivers USDT)", C.EID_ETHEREUM);
        _logQuote(stargateModule, "Arbitrum", C.EID_ARBITRUM);
        _logQuote(stargateModule, "HyperEVM", C.EID_HYPEREVM);
    }

    function _logQuote(StargateModule stargateModule, string memory label, uint32 eid) internal view {
        (, uint256 fee) = stargateModule.getBridgeFee(eid, C.USDT0, 1_000e6, msg.sender, 50);
        require(fee > 0, string.concat(label, ": route quotes a zero native fee"));
        console.log("  %s (eid %s): %s", label, eid, fee);
    }

    /// @dev Each dispatcher's live USDT recipient — the value USDT0 mirrors. A dispatcher that does
    ///      not settle USDT would be a prod-shaped exception and is rejected rather than guessed at.
    function _usdtRecipients(address[] memory dispatchers) internal view returns (address[] memory recipients) {
        recipients = new address[](dispatchers.length);
        for (uint256 i; i < dispatchers.length; ++i) {
            recipients[i] = ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(C.USDT);
            require(recipients[i] != address(0), string.concat(DISPATCHER_KEYS[i], ": no USDT recipient to mirror on dev"));
            require(
                ISettlementDispatcherLike(dispatchers[i]).getSettlementRecipient(C.USDT0) == address(0),
                string.concat(DISPATCHER_KEYS[i], ": USDT0 recipient already set")
            );
        }
    }

    /// @dev The OFT is prod infrastructure that dev shares as-is, so check it is what we think it is
    function _requireOft() internal view {
        require(IOftLike(C.USDT0_OFT_OP).token() == C.USDT0, "OP OFT does not wrap USDT0");
        require(!IOftLike(C.USDT0_OFT_OP).approvalRequired(), "OP OFT now needs an approval: re-check _bridgeOft");
        require(IOAppPeers(C.USDT0_OFT_OP).peers(C.EID_ETHEREUM) == bytes32(uint256(uint160(C.USDT0_OFT_ETHEREUM))), "Ethereum peer");
        require(IOAppPeers(C.USDT0_OFT_OP).peers(C.EID_ARBITRUM) == bytes32(uint256(uint160(C.USDT0_OFT_ARBITRUM))), "Arbitrum peer");
        require(IOAppPeers(C.USDT0_OFT_OP).peers(C.EID_HYPEREVM) == bytes32(uint256(uint160(C.USDT0_OFT_HYPEREVM))), "HyperEVM peer");
    }

    function _dispatchers() internal view returns (address[] memory dispatchers) {
        dispatchers = new address[](DISPATCHER_KEYS.length);
        for (uint256 i; i < DISPATCHER_KEYS.length; ++i) {
            dispatchers[i] = _devAddress(string.concat(".addresses.", DISPATCHER_KEYS[i]));
        }
    }

    function _devAddress(string memory key) internal view returns (address) {
        return stdJson.readAddress(readDeploymentFile(), key);
    }

    function _requireDevOptimism() internal view {
        require(block.chainid == 10, "Must run on Optimism (10)");
        require(isEqualString(getEnv(), "dev"), "dev-only: these are the dev cash deployments");
    }
}
