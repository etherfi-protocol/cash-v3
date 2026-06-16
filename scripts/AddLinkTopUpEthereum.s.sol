// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { TopUpFactory } from "../src/top-up/TopUpFactory.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title AddLinkTopUpEthereum
 * @author ether.fi
 * @notice Registers LINK for top-up bridging from Ethereum to Optimism (the Cash chain)
 *         via etherfi's OFT adapter, so the top-up relayer can bridge a user's mainnet LINK deposit
 *         into iLINK on Optimism. Mirrors the weETH `oftBridgeAdapter` top-up config.
 * @dev `TopUpFactory.setTokenConfig` routes a deposited token through a bridge adapter to a recipient
 *      on the destination chain. For LINK the adapter is the EtherFiOFTBridgeAdapter, whose
 *      `additionalData` is `abi.encode(address oftAdapter, uint32 destEid)`. `setTokenConfig` is
 *      `onlyRoleRegistryOwner`, so the broadcaster must be the dev RoleRegistry owner. Idempotent.
 *      Run on Ethereum mainnet:
 *
 *        ENV=dev forge script scripts/AddLinkTopUpEthereum.s.sol \
 *          --rpc-url $MAINNET_RPC --account dev-owner --sender <dev-owner-address> --broadcast
 */
contract AddLinkTopUpEthereum is Utils {
    /// @notice Native LINK on Ethereum mainnet (the deposited token users top up with).
    address constant LINK_MAINNET = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    /// @notice etherfi LINK OFT adapter on Ethereum dev (lock-on-deposit). Locks LINK and sends the
    ///         LayerZero message that mints iLINK on Optimism.
    address constant LINK_OFT_ADAPTER = 0xd7a747f337fFC340d536Eda4da318bDA7De9eaaa;

    /// @notice TopUpDest on Optimism dev (receives bridged iLINK and credits user safes).
    address constant TOP_UP_DEST_OPTIMISM = 0x06fe42Cf3C63412f1955758ce2798709476a38fd;

    /// @notice Cash chain (Optimism) destination.
    uint256 constant OPTIMISM_CHAIN_ID = 10;
    uint32 constant OPTIMISM_EID = 30_111;

    // DECISION (top-up slippage): max slippage the OFT bridge will tolerate, in bps. Matches the
    // weETH oftBridgeAdapter config. TopUpFactory caps this at 200 bps.
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

        address[] memory tokens = new address[](1);
        tokens[0] = LINK_MAINNET;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = TopUpFactory.TokenConfig({ bridgeAdapter: oftBridgeAdapter, recipientOnDestChain: TOP_UP_DEST_OPTIMISM, maxSlippageInBps: MAX_SLIPPAGE_BPS, additionalData: abi.encode(LINK_OFT_ADAPTER, OPTIMISM_EID) });

        // Signer comes from the CLI (--account keystore, --ledger, etc.), never an env var or arg.
        vm.startBroadcast();
        topUpFactory.setTokenConfig(tokens, chainIds, configs);
        vm.stopBroadcast();

        console.log("Registered LINK top-up (Ethereum -> Optimism) on TopUpFactory");
        console.log("  TopUpFactory:           ", address(topUpFactory));
        console.log("  LINK (mainnet):         ", LINK_MAINNET);
        console.log("  OFT adapter:            ", LINK_OFT_ADAPTER);
        console.log("  recipient (OP TopUpDest):", TOP_UP_DEST_OPTIMISM);
        console.log("  dest chainId / EID:     ", OPTIMISM_CHAIN_ID, OPTIMISM_EID);
    }
}
