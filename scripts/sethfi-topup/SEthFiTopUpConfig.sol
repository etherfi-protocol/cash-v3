// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { EtherFiDeployerHelper } from "../utils/EtherFiDeployerHelper.sol";

/**
 * @title SEthFiTopUpConfig
 * @notice Shared constants for the sETHFI top-up rail from Arbitrum and Base.
 *
 *         The sETHFI LayerZero teller is hub and spoke: the Arbitrum and Base tellers peer only
 *         with Ethereum (eid 30101), so a direct Arb/Base -> Optimism send is impossible. The
 *         route therefore has two legs, the same shape as Base USDT today:
 *           1. Arb/Base TopUpFactory.bridge(sETHFI, amount, 10) sends to the Ethereum
 *              TopUpFactory through the teller (this rail);
 *           2. Ethereum TopUpFactory.bridge(sETHFI, amount, 10) sends on to the OP TopUpDest
 *              with the config that is already live on Ethereum.
 *         The config is keyed by chain 10, the final destination, because that is what the
 *         top-up service passes to `bridge`.
 */
abstract contract SEthFiTopUpConfig is EtherFiDeployerHelper {
    using stdJson for string;

    uint256 internal constant ARBITRUM = 42161;
    uint256 internal constant BASE = 8453;
    uint256 internal constant OP_CHAIN_ID = 10;

    /// @dev sETHFI BoringVault, same address on Ethereum, Arbitrum, Base and Optimism
    address internal constant SETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;
    /// @dev sETHFI LayerZero teller, same address on every chain
    address internal constant SETHFI_TELLER = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;
    uint32 internal constant ETHEREUM_EID = 30101;
    /// @dev Matches the live Ethereum sETHFI config. The liquid adapter ignores it, but
    ///      setTokenConfig caps it, so keep it at the value reviewers already know.
    uint96 internal constant MAX_SLIPPAGE_BPS = 50;

    /// @dev Live EtherFiLiquidBridgeAdapter on Base (deployments/mainnet/8453/deployments.json)
    address internal constant BASE_LIQUID_ADAPTER = 0x44E95b85CE77E4c7cfc6f866b37553b5Cbcf6D32;
    /// @dev Arbitrum has no liquid adapter yet: CREATE3 via the EtherFiDeployer under this salt
    string internal constant ARB_ADAPTER_SALT = "Prod.SEthFiTopUp.Arbitrum.EtherFiLiquidBridgeAdapter";
    address internal constant ARB_LIQUID_ADAPTER = 0x37F49CBc160939c6e8d74d0AD138557965b7CCbE;

    function _adapterFor(uint256 chainId) internal pure returns (address) {
        if (chainId == ARBITRUM) return ARB_LIQUID_ADAPTER;
        if (chainId == BASE) return BASE_LIQUID_ADAPTER;
        revert("sETHFI top-up: run on Arbitrum or Base");
    }

    /// @dev The Ethereum TopUpFactory, which receives leg 1 and bridges leg 2
    function _ethereumTopUpFactory() internal view returns (address) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/1/deployments.json");
        return vm.readFile(path).readAddress(".addresses.TopUpSourceFactory");
    }

    function _sEthFiTokenConfig(address adapter) internal view returns (TopUpFactory.TokenConfig memory) {
        return TopUpFactory.TokenConfig({
            bridgeAdapter: adapter,
            recipientOnDestChain: _ethereumTopUpFactory(),
            maxSlippageInBps: MAX_SLIPPAGE_BPS,
            additionalData: abi.encode(SETHFI_TELLER, ETHEREUM_EID)
        });
    }
}
