// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { TopUpFactory } from "../src/top-up/TopUpFactory.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title AddCollateralOftsTopUpEthereum
 * @author ether.fi
 * @notice Registers wSPYx and PAXG for top-up bridging from Ethereum to Optimism (the Cash chain)
 *         via etherfi's OFT adapters, so the top-up relayer can bridge a user's mainnet deposit
 *         into the wrapped asset on Optimism. Mirrors the weETH/LINK `oftBridgeAdapter` top-up config.
 * @dev `TopUpFactory.setTokenConfig` routes a deposited token through a bridge adapter to a recipient
 *      on the destination chain. For these tokens the adapter is the EtherFiOFTBridgeAdapter, whose
 *      `additionalData` is `abi.encode(address oftAdapter, uint32 destEid)`. `setTokenConfig` is
 *      `onlyRoleRegistryOwner`, so the broadcaster must be the dev RoleRegistry owner. Idempotent.
 *      Run on Ethereum mainnet:
 *
 *        ENV=dev forge script scripts/AddCollateralOftsTopUpEthereum.s.sol \
 *          --rpc-url $MAINNET_RPC --account dev-owner --sender <dev-owner-address> --broadcast
 */
contract AddCollateralOftsTopUpEthereum is Utils {
    /// @notice Canonical wSPYx on Ethereum mainnet (the deposited token users top up with).
    address constant WSPYX_MAINNET = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;

    /// @notice etherfi wSPYx OFT adapter on Ethereum dev (lock-on-deposit). Locks wSPYx and sends the
    ///         LayerZero message that mints the wrapped asset on Optimism.
    address constant WSPYX_OFT_ADAPTER = 0x24f64E0a6C366B32e973C23d4DEdB4527E0C422A;

    /// @notice PAXG on Ethereum mainnet (the deposited token users top up with).
    address constant PAXG_MAINNET = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;

    /// @notice etherfi PAXG OFT adapter on Ethereum dev (lock-on-deposit). Locks PAXG and sends the
    ///         LayerZero message that mints the wrapped asset on Optimism.
    address constant PAXG_OFT_ADAPTER = 0x770d31FF00F6795D42349040D5BD74AAebE60FF4;

    /// @notice TopUpDest on Optimism dev (receives bridged tokens and credits user safes).
    address constant TOP_UP_DEST_OPTIMISM = 0x06fe42Cf3C63412f1955758ce2798709476a38fd;

    /// @notice Cash chain (Optimism) destination.
    uint256 constant OPTIMISM_CHAIN_ID = 10;
    uint32 constant OPTIMISM_EID = 30_111;

    // DECISION (top-up slippage): max slippage the OFT bridge will tolerate, in bps. Matches the
    // weETH/LINK oftBridgeAdapter config. TopUpFactory caps this at 200 bps.
    uint96 constant MAX_SLIPPAGE_BPS = 50; // 0.5%

    function run() public {
        require(block.chainid == 1, "run on Ethereum (chainId 1)");
        // The hardcoded constants are dev OFT/TopUpDest addresses, and the env-read TopUpFactory
        // below must resolve to the dev deployment. getEnv() defaults to "mainnet", and chainId
        // alone cannot tell dev from prod (both live on chain 1), so fail loudly unless ENV=dev.
        require(isEqualString(getEnv(), "dev"), "dev only");

        string memory deployments = readTopUpSourceDeployment();
        TopUpFactory topUpFactory = TopUpFactory(payable(stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory")));
        address oftBridgeAdapter = stdJson.readAddress(deployments, ".addresses.EtherFiOFTBridgeAdapter");

        address[] memory tokens = new address[](2);
        tokens[0] = WSPYX_MAINNET;
        tokens[1] = PAXG_MAINNET;
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        chainIds[1] = OPTIMISM_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](2);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: oftBridgeAdapter, recipientOnDestChain: TOP_UP_DEST_OPTIMISM, maxSlippageInBps: MAX_SLIPPAGE_BPS, additionalData: abi.encode(WSPYX_OFT_ADAPTER, OPTIMISM_EID) });
        configs[1] = TopUpFactory.TokenConfig({ bridgeAdapter: oftBridgeAdapter, recipientOnDestChain: TOP_UP_DEST_OPTIMISM, maxSlippageInBps: MAX_SLIPPAGE_BPS, additionalData: abi.encode(PAXG_OFT_ADAPTER, OPTIMISM_EID) });

        // Signer comes from the CLI (--account keystore, --ledger, etc.), never an env var or arg.
        vm.startBroadcast();
        topUpFactory.setTokenConfig(tokens, chainIds, configs);
        vm.stopBroadcast();

        console.log("Registered wSPYx + PAXG top-up (Ethereum -> Optimism) on TopUpFactory");
        console.log("  TopUpFactory:            ", address(topUpFactory));
        console.log("  wSPYx (mainnet):         ", WSPYX_MAINNET);
        console.log("  wSPYx OFT adapter:       ", WSPYX_OFT_ADAPTER);
        console.log("  PAXG (mainnet):          ", PAXG_MAINNET);
        console.log("  PAXG OFT adapter:        ", PAXG_OFT_ADAPTER);
        console.log("  recipient (OP TopUpDest):", TOP_UP_DEST_OPTIMISM);
        console.log("  dest chainId / EID:      ", OPTIMISM_CHAIN_ID, OPTIMISM_EID);
    }
}
