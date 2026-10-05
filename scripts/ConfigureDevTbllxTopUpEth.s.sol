// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IOFT } from "../src/interfaces/IOFT.sol";
import { IRoleRegistry } from "../src/interfaces/IRoleRegistry.sol";
import { TopUpFactory } from "../src/top-up/TopUpFactory.sol";
import { Utils } from "./utils/Utils.sol";

/**
 * @title ConfigureDevTbllxTopUpEth
 * @notice Ethereum (dev) top-up route for wTBLLx: Ethereum -> Optimism, over the PROD wTBLLx OFT
 *         adapter. The dev counterpart of the prod Ethereum listing bundle's last tx (3CP-640,
 *         `TopUpFactory.setTokenConfig`); every other tx in that bundle — the OFT adapter deploy,
 *         rate limits, peer, enforced options, relay rate config, PriceRelay subscription — is
 *         prod-side infra that dev shares as-is.
 *
 *         Dev differs from prod in exactly two fields, both of them dev's own contracts: the bridge
 *         adapter (the dev `EtherFiOFTBridgeAdapter` on Ethereum) and the destination recipient (the
 *         dev `TopUpDest` on Optimism). `additionalData` names the PROD wTBLLx OFT adapter and the
 *         OP endpoint id, so a dev top-up moves value over the same LayerZero pathway as prod and
 *         mints the PROD iwTBLLx on Optimism — to the dev TopUpDest. maxSlippageInBps matches the
 *         prod value (and every other OFT route on this factory); `TopUpFactory` caps it at 200 bps.
 *
 *         The plain OFT adapter is the right one here — wTBLLx is the ERC-4626 that actually bridges,
 *         so nothing needs wrapping on the way out and the `StockOFTBridgeAdapter` (raw-stock ->
 *         wrapper -> OFT) is not involved. Enforced SEND options live on the prod OFT adapter, set by
 *         the prod bundle; Backed OFTs ship with none by default and `quoteSend` reverts
 *         `Executor_NoOptions` without them, which is another thing dev inherits rather than repeats.
 *
 *         The Optimism side needs no matching TopUpDest token config — `TopUpDest` has no per-token
 *         config, only a balance and, for the lend hand-off, a LendGateway registration
 *         (`supplyTopUpToLend` no-ops unless `lendGateway.isRegistered(token)`), which
 *         scripts/aave-v4/SupportTbllxCollateral.s.sol writes.
 *
 * Usage (simulate by dropping --broadcast; the broadcast wallet must be the dev RoleRegistry OWNER —
 * `setTokenConfig` is onlyRoleRegistryOwner, not a role):
 *   source .env && ENV=dev forge script \
 *     scripts/ConfigureDevTbllxTopUpEth.s.sol:ConfigureDevTbllxTopUpEth \
 *     --rpc-url $MAINNET_RPC --broadcast -vvvv
 */
contract ConfigureDevTbllxTopUpEth is Utils {
    /// @dev Mainnet wTBLLx — the ERC-4626 over TBLLx, and the token that actually bridges.
    address constant WTBLLX_MAINNET = 0x461b25b99606Fe169D6F0dD6816650eF6536403E;
    /// @dev PROD wTBLLx OFT adapter on Ethereum (cash-mainnet-asset-listing
    ///      StockAssets.wtbllx().adapterEth, deployed by 3CP-640).
    address constant PROD_WTBLLX_OFT_ADAPTER = 0x8C03Bba46607F0e1bd51c6860293040f0477A1D0;
    /// @dev DEV TopUpDest on Optimism (deployments/dev/10/deployments.json).
    address constant DEV_TOP_UP_DEST_OPTIMISM = 0x06fe42Cf3C63412f1955758ce2798709476a38fd;

    uint32 constant OP_EID = 30_111;
    uint256 constant OPTIMISM_CHAIN_ID = 10;
    /// @dev Matches the prod wTBLLx route and the existing weETH/LINK OFT routes on this factory.
    uint96 constant MAX_SLIPPAGE_BPS = 50;

    function run() public {
        require(block.chainid == 1, "Must run on Ethereum (1)");
        require(isEqualString(getEnv(), "dev"), "dev-only: the factory and recipient are the dev deployments");

        string memory deployments = readDeploymentFile();
        TopUpFactory factory = TopUpFactory(payable(stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory")));
        address bridgeAdapter = stdJson.readAddress(deployments, ".addresses.EtherFiOFTBridgeAdapter");
        IRoleRegistry roleRegistry = IRoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));

        address sender = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(roleRegistry.owner() == sender, "sender is not the RoleRegistry owner; setTokenConfig is onlyRoleRegistryOwner");

        // Wiring checks on the prod rails this route rides. The adapter's `token()` is the single
        // most consequential one: a wrong adapter would silently bridge the wrong asset.
        require(WTBLLX_MAINNET.code.length > 0, "wTBLLx has no code on Ethereum");
        require(PROD_WTBLLX_OFT_ADAPTER.code.length > 0, "prod wTBLLx OFT adapter has no code: the prod Ethereum listing bundle has not executed");
        require(IOFT(PROD_WTBLLX_OFT_ADAPTER).token() == WTBLLX_MAINNET, "prod OFT adapter does not wrap wTBLLx");

        address[] memory tokens = new address[](1);
        tokens[0] = WTBLLX_MAINNET;
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        TopUpFactory.TokenConfig[] memory configs = new TopUpFactory.TokenConfig[](1);
        configs[0] = _tokenConfig(bridgeAdapter);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        factory.setTokenConfig(tokens, chainIds, configs);
        vm.stopBroadcast();

        TopUpFactory.TokenConfig memory recorded = factory.getTokenConfig(WTBLLX_MAINNET, OPTIMISM_CHAIN_ID);
        TopUpFactory.TokenConfig memory expected = _tokenConfig(bridgeAdapter);
        require(recorded.bridgeAdapter == expected.bridgeAdapter, "bridgeAdapter mismatch");
        require(recorded.recipientOnDestChain == expected.recipientOnDestChain, "recipientOnDestChain mismatch");
        require(recorded.maxSlippageInBps == expected.maxSlippageInBps, "maxSlippageInBps mismatch");
        require(keccak256(recorded.additionalData) == keccak256(expected.additionalData), "additionalData mismatch");

        console.log("wTBLLx top-up route (ETH -> OP) configured on dev");
        console.log("  bridgeAdapter:       ", recorded.bridgeAdapter);
        console.log("  recipientOnDestChain:", recorded.recipientOnDestChain);
        console.log("  prod OFT adapter:    ", PROD_WTBLLX_OFT_ADAPTER);
    }

    function _tokenConfig(address bridgeAdapter) internal pure returns (TopUpFactory.TokenConfig memory) {
        return TopUpFactory.TokenConfig({ bridgeAdapter: bridgeAdapter, recipientOnDestChain: DEV_TOP_UP_DEST_OPTIMISM, maxSlippageInBps: MAX_SLIPPAGE_BPS, additionalData: abi.encode(PROD_WTBLLX_OFT_ADAPTER, OP_EID) });
    }
}
