// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IOFT } from "../../src/interfaces/IOFT.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { IOAppPeers } from "./IOAppPeers.sol";
import { Utils } from "./Utils.sol";

/**
 * @title USDT0TopUpConfig
 * @author ether.fi
 * @notice Shared rail data + on-chain sanity checks for the USD₮0 (LayerZero OFT) top-up lanes
 *         added/repointed by COR-1757 (Arbitrum -> OP) and COR-1759 (Ethereum -> OP,
 *         HyperEVM -> OP). All three legs share one destination (OP `TopUpDest`) and one
 *         bridge kind (`EtherFiOFTBridgeAdapter` / `oftBridgeAdapter`), so a single struct plus
 *         a switch on `block.chainid` covers every source chain touched by either ticket.
 *
 * @dev Addresses below were verified on-chain (mesh symmetry via `peers()`, `token()`, and
 *      `EtherFiOFTBridgeAdapter` code presence) as part of the COR-1757/1759 investigation, on
 *      2026-09-23:
 *        - Arbitrum OFT  0x14E4A1B13bf7F943c8ff7C51fb60FA964A298D92 (approvalRequired=false)
 *        - Ethereum OAdapter 0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee (approvalRequired=true,
 *          locks legacy USDT 0xdAC17F958D2ee523a2206206994597C13D831ec7)
 *        - Optimism OFT  0xf03b4D9aC1D5d1e7c4ceF54C2a313b9Fe051a0aD
 *        - HyperEVM OFT  0x904861a24F30EC96ea7CFC3bE9EA4B476d237e98 (mainnet only, see below)
 *      Every pairwise `peers(eid)` between these four was read back live and matches.
 *
 * @dev HyperEVM's oftAdapter is NOT the same address in both environments. Mainnet uses the
 *      verified mesh member above; the pre-existing DEV fixture entry instead names the dev USDT
 *      token itself (`0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb`) as its own "oftAdapter" — and
 *      that address does NOT implement `token()`/`peers()` (calls revert on-chain). This predates
 *      COR-1759 and this change does not touch it (`keep the same oftAdapter` per spec), so
 *      `_assertOftWiring` is allowed to tolerate that one revert with a loud warning instead of
 *      failing the whole dev run.
 */
abstract contract USDT0TopUpConfig is Utils {
    using stdJson for string;

    /// @notice Prod operating Safe. Proposer + executor on `ETHERFI_TIMELOCK` on every mainnet
    ///         chain touched here (verified via `hasRole` on 2026-09-23) — see the governance
    ///         note in `SetUSDT0TopUpConfig3CP.s.sol` for why this is a timelock path, not a
    ///         direct Safe call.
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /// @notice Optimism mainnet LayerZero endpoint ID — every rail here terminates on OP.
    uint32 internal constant OP_EID = 30111;
    /// @notice Optimism chain ID — the `destChainId` key of every TopUpFactory config here.
    uint256 internal constant OP_CHAIN_ID = 10;

    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    uint256 internal constant HYPEREVM_CHAIN_ID = 999;

    /// @notice Slippage headroom applied to every rail here (`quoteOFT` returns 1:1 today; this
    ///         is headroom against USD₮0 enabling a fee later, not a current cost). Constant
    ///         across chains/envs per spec, and well inside `TopUpFactory.MAX_ALLOWED_SLIPPAGE`
    ///         (200 bps, confirmed live on chains 1/999/42161/10 on 2026-09-23).
    uint96 internal constant MAX_SLIPPAGE_BPS = 50;

    // ---- Token / OFT addresses (verified on-chain, see contract natspec) ----

    address internal constant ARB_USDT0 = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;
    address internal constant ARB_USDT0_OFT = 0x14E4A1B13bf7F943c8ff7C51fb60FA964A298D92;

    address internal constant ETH_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant ETH_USDT_OADAPTER = 0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee;

    address internal constant HYPE_USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    /// @dev Mainnet-only verified OFT. Dev keeps its pre-existing (non-compliant) self-adapter —
    ///      see the contract natspec.
    address internal constant HYPE_USDT0_OFT_MAINNET = 0x904861a24F30EC96ea7CFC3bE9EA4B476d237e98;

    /// @notice One rail: the token being configured, its human name (must match the fixture
    ///         `name` field so `output/` bundles read the same as `top-up-fixtures.json`), the
    ///         OFT/OAdapter that moves it, and whether that adapter tolerates a failed
    ///         `token()`/`peers()` read (true only for dev HyperEVM, see natspec).
    struct Rail {
        address token;
        string name;
        address oftAdapter;
        bool tolerateWiringCheckRevert;
    }

    /// @dev Selects the rail for `block.chainid`, branching dev vs mainnet only where the
    ///      on-chain adapter actually differs (HyperEVM). Reverts on any other chain so a script
    ///      run against the wrong `--rpc-url` fails loudly instead of silently configuring
    ///      nothing.
    function _rail() internal view returns (Rail memory) {
        if (block.chainid == ARBITRUM_CHAIN_ID) {
            return Rail({ token: ARB_USDT0, name: "usdt0", oftAdapter: ARB_USDT0_OFT, tolerateWiringCheckRevert: false });
        } else if (block.chainid == ETHEREUM_CHAIN_ID) {
            return Rail({ token: ETH_USDT, name: "USDT", oftAdapter: ETH_USDT_OADAPTER, tolerateWiringCheckRevert: false });
        } else if (block.chainid == HYPEREVM_CHAIN_ID) {
            address oftAdapter = _isDev() ? HYPE_USDT0 : HYPE_USDT0_OFT_MAINNET;
            return Rail({ token: HYPE_USDT0, name: "usdt", oftAdapter: oftAdapter, tolerateWiringCheckRevert: _isDev() });
        }
        revert("USDT0TopUpConfig: unsupported chain - must run on 42161 (Ethereum), 1 (Ethereum) or 999 (HyperEVM)");
    }

    function _isDev() internal view returns (bool) {
        return isEqualString(getEnv(), "dev");
    }

    /// @dev The EtherFiOFTBridgeAdapter for the CURRENT chain/env, read from the source chain's
    ///      own deployments.json (never hardcoded here, so a stale manifest fails the run instead
    ///      of silently wiring the wrong adapter).
    function _bridgeAdapter() internal view returns (address adapter) {
        string memory deployments = readDeploymentFile();
        adapter = deployments.readAddress(".addresses.EtherFiOFTBridgeAdapter");
        require(adapter.code.length > 0, "EtherFiOFTBridgeAdapter has no code on this chain/env");
    }

    /// @dev OP `TopUpDest` for the current ENV — the recipient on every rail here.
    function _topUpDestOptimism() internal view returns (address dest) {
        string memory file = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", vm.toString(OP_CHAIN_ID), "/deployments.json");
        dest = vm.readFile(file).readAddress(".addresses.TopUpDest");
        require(dest != address(0), "TopUpDest on Optimism not found");
    }

    /// @dev The `(bridgeAdapter, destChainId, config)` triple `setTokenConfig` expects, built
    ///      from `_rail()`. `additionalData` is `abi.encode(oftAdapter, destEid)`, matching
    ///      `EtherFiOFTBridgeAdapter.bridge`.
    function _tokenConfig(Rail memory rail, address bridgeAdapter, address recipient) internal pure returns (TopUpFactory.TokenConfig memory) {
        return TopUpFactory.TokenConfig({ bridgeAdapter: bridgeAdapter, recipientOnDestChain: recipient, maxSlippageInBps: MAX_SLIPPAGE_BPS, additionalData: abi.encode(rail.oftAdapter, OP_EID) });
    }

    /**
     * @dev Sanity check called before anything is broadcast or bundled: the OFT adapter
     *      actually locks/mints the token being configured, and it has a live LayerZero peer
     *      for the destination eid. Catches almost any address typo. Tolerates a revert ONLY
     *      for the one pre-existing exception documented on the contract (dev HyperEVM); every
     *      other chain/env must pass or the run aborts before touching anything.
     */
    function _assertOftWiring(Rail memory rail) internal view {
        if (!rail.tolerateWiringCheckRevert) {
            require(IOFT(rail.oftAdapter).token() == rail.token, string.concat(rail.name, ": OFT adapter does not front the configured token"));
            bytes32 peer = IOAppPeers(rail.oftAdapter).peers(OP_EID);
            require(peer != bytes32(0), string.concat(rail.name, ": OFT adapter has no LayerZero peer for the OP eid"));
            return;
        }

        try IOFT(rail.oftAdapter).token() returns (address token) {
            require(token == rail.token, string.concat(rail.name, ": OFT adapter does not front the configured token"));
            bytes32 peer = IOAppPeers(rail.oftAdapter).peers(OP_EID);
            require(peer != bytes32(0), string.concat(rail.name, ": OFT adapter has no LayerZero peer for the OP eid"));
        } catch {
            console.log("WARNING: %s oftAdapter's token()/peers() call reverted - pre-existing dev-only exception, NOT re-verified. See USDT0TopUpConfig natspec.", rail.name);
        }
    }

    // ---- single-element array helpers (setTokenConfig is batch-shaped) ----

    function _asArray(address value) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = value;
    }

    function _asArray(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    function _asArray(TopUpFactory.TokenConfig memory value) internal pure returns (TopUpFactory.TokenConfig[] memory arr) {
        arr = new TopUpFactory.TokenConfig[](1);
        arr[0] = value;
    }
}
