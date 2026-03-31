// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { stdJson } from "forge-std/StdJson.sol";

import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { Utils } from "./Utils.sol";

/// @title TopUpConfigHelper
/// @notice Shared helpers for parsing TopUpFactory token bridge configs from fixture JSON.
///         Used by both the EOA and Gnosis config scripts.
abstract contract TopUpConfigHelper is Utils {
    TopUpFactory topUpFactory;

    // ── Adapter addresses (loaded from deployments) ──
    address stargateAdapter;
    address scrollERC20BridgeAdapter;
    address baseWithdrawERC20BridgeAdapter;
    address etherFiOFTBridgeAdapter;
    address etherFiLiquidBridgeAdapter;
    address optimismBridgeAdapter;
    address hopBridgeAdapter;
    address cctpAdapter;

    // ═══════════════════════════════════════════════════════════════
    //                  FIXTURE PARSING
    // ═══════════════════════════════════════════════════════════════

    /// @notice Parses all token configs from the fixture file for the current chain
    function parseAllTokenConfigs()
        internal
        view
        returns (address[] memory tokens, uint256[] memory chainIds, TopUpFactory.TokenConfig[] memory configs)
    {
        string memory fixturesFile = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/fixtures/top-up-fixtures.json");
        string memory fixtures = vm.readFile(fixturesFile);
        string memory chainId = vm.toString(block.chainid);

        string[] memory destChainIds = vm.parseJsonStringArray(fixtures, string.concat(".", chainId, ".destChainIds"));

        // Count total entries
        uint256 totalCount;
        for (uint256 d = 0; d < destChainIds.length; d++) {
            totalCount += _getArrayLength(fixtures, string.concat(".", chainId, ".tokenConfigs.", destChainIds[d]));
        }

        tokens = new address[](totalCount);
        chainIds = new uint256[](totalCount);
        configs = new TopUpFactory.TokenConfig[](totalCount);

        uint256 idx;
        for (uint256 d = 0; d < destChainIds.length; d++) {
            string memory destChainId = destChainIds[d];
            uint256 count = _getArrayLength(fixtures, string.concat(".", chainId, ".tokenConfigs.", destChainId));
            address recipient = _getRecipient(destChainId);

            for (uint256 i = 0; i < count; i++) {
                string memory base = string.concat(".", chainId, ".tokenConfigs.", destChainId, "[", vm.toString(i), "]");

                tokens[idx] = stdJson.readAddress(fixtures, string.concat(base, ".address"));
                chainIds[idx] = vm.parseUint(destChainId);
                configs[idx].recipientOnDestChain = recipient;
                configs[idx].maxSlippageInBps = uint96(stdJson.readUint(fixtures, string.concat(base, ".maxSlippageInBps")));

                string memory bridge = stdJson.readString(fixtures, string.concat(base, ".bridge"));
                _parseBridgeConfig(configs[idx], bridge, fixtures, base);

                string memory name = stdJson.readString(fixtures, string.concat(base, ".name"));
                require(configs[idx].recipientOnDestChain != address(0), string.concat("No recipient: ", name));
                require(configs[idx].bridgeAdapter != address(0), string.concat("No adapter: ", name));

                idx++;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    //                  ADAPTER LOADING
    // ═══════════════════════════════════════════════════════════════

    function _loadAdapters(string memory deployments) internal {
        stargateAdapter = _tryAddr(deployments, "StargateAdapter");
        etherFiOFTBridgeAdapter = _tryAddr(deployments, "EtherFiOFTBridgeAdapter");
        etherFiLiquidBridgeAdapter = _tryAddr(deployments, "EtherFiLiquidBridgeAdapter");
        scrollERC20BridgeAdapter = _tryAddr(deployments, "ScrollERC20BridgeAdapter");
        baseWithdrawERC20BridgeAdapter = _tryAddr(deployments, "BaseWithdrawERC20BridgeAdapter");
        optimismBridgeAdapter = _tryAddr(deployments, "OptimismBridgeAdapter");
        hopBridgeAdapter = _tryAddr(deployments, "HopBridgeAdapter");
        cctpAdapter = _tryAddr(deployments, "CCTPAdapter");
    }

    function _tryAddr(string memory json, string memory key) internal pure returns (address) {
        try vm.parseJsonAddress(json, string.concat(".addresses.", key)) returns (address a) { return a; }
        catch { return address(0); }
    }

    // ═══════════════════════════════════════════════════════════════
    //                  BRIDGE CONFIG PARSERS
    // ═══════════════════════════════════════════════════════════════

    function _parseBridgeConfig(
        TopUpFactory.TokenConfig memory config,
        string memory bridge,
        string memory json,
        string memory base
    ) internal view {
        bytes32 h = keccak256(bytes(bridge));

        if (h == keccak256("stargate")) {
            _parseStargate(config, json, base);
        } else if (h == keccak256("oftBridgeAdapter") || h == keccak256("oftBridgeAdapterMainnet")) {
            _parseOFT(config, json, base);
        } else if (h == keccak256("liquidBridgeAdapter")) {
            _parseLiquid(config, json, base);
        } else if (h == keccak256("scrollERC20BridgeAdapter")) {
            _parseScrollBridge(config, json, base);
        } else if (h == keccak256("baseWithdrawErc20BridgeAdapter")) {
            _parseBaseWithdraw(config, json, base);
        } else if (h == keccak256("optimismBridgeAdapter")) {
            _parseOptimismBridge(config, json, base);
        } else if (h == keccak256("hopBridgeAdapter")) {
            _parseHop(config, json, base);
        } else if (h == keccak256("cctp")) {
            _parseCCTP(config, json, base);
        } else {
            revert(string.concat("Unknown bridge: ", bridge));
        }
    }

    /// @dev Stargate V2: additionalData = (address stargatePool, uint32 destEid)
    function _parseStargate(TopUpFactory.TokenConfig memory config, string memory json, string memory base) internal view {
        config.bridgeAdapter = stargateAdapter;
        config.additionalData = abi.encode(
            stdJson.readAddress(json, string.concat(base, ".stargatePool")),
            uint32(stdJson.readUint(json, string.concat(base, ".destEid")))
        );
    }

    /// @dev OFT / OFT Mainnet: additionalData = (address oftAdapter, uint32 destEid)
    function _parseOFT(TopUpFactory.TokenConfig memory config, string memory json, string memory base) internal view {
        config.bridgeAdapter = etherFiOFTBridgeAdapter;
        config.additionalData = abi.encode(
            stdJson.readAddress(json, string.concat(base, ".oftAdapter")),
            uint32(stdJson.readUint(json, string.concat(base, ".destEid")))
        );
    }

    /// @dev Liquid (Boring Vault teller): additionalData = (address teller, uint32 destEid)
    function _parseLiquid(TopUpFactory.TokenConfig memory config, string memory json, string memory base) internal view {
        config.bridgeAdapter = etherFiLiquidBridgeAdapter;
        config.additionalData = abi.encode(
            stdJson.readAddress(json, string.concat(base, ".teller")),
            uint32(stdJson.readUint(json, string.concat(base, ".destEid")))
        );
    }

    /// @dev Scroll native ERC20 bridge: additionalData = (address gateway, uint256 gasLimit)
    function _parseScrollBridge(TopUpFactory.TokenConfig memory config, string memory json, string memory base) internal view {
        config.bridgeAdapter = scrollERC20BridgeAdapter;
        config.additionalData = abi.encode(
            stdJson.readAddress(json, string.concat(base, ".scrollGatewayRouter")),
            stdJson.readUint(json, string.concat(base, ".gasLimitForScrollGateway"))
        );
    }

    /// @dev Base L2 withdraw: additionalData = (uint256 gasLimit, bytes extraData)
    function _parseBaseWithdraw(TopUpFactory.TokenConfig memory config, string memory json, string memory base) internal view {
        config.bridgeAdapter = baseWithdrawERC20BridgeAdapter;
        config.additionalData = abi.encode(
            stdJson.readUint(json, string.concat(base, ".gasLimitForBaseGateway")),
            hex''
        );
        config.recipientOnDestChain = address(topUpFactory);
    }

    /// @dev Optimism L1 native bridge: additionalData = (address l2Token, uint32 minGasLimit)
    function _parseOptimismBridge(TopUpFactory.TokenConfig memory config, string memory json, string memory base) internal view {
        config.bridgeAdapter = optimismBridgeAdapter;
        config.additionalData = abi.encode(
            stdJson.readAddress(json, string.concat(base, ".l2Token")),
            uint32(stdJson.readUint(json, string.concat(base, ".minGasLimit")))
        );
    }

    /// @dev Hop V2 (Frax): additionalData = (address hopContract, address oftToken, uint32 destEid)
    function _parseHop(TopUpFactory.TokenConfig memory config, string memory json, string memory base) internal view {
        config.bridgeAdapter = hopBridgeAdapter;
        config.additionalData = abi.encode(
            stdJson.readAddress(json, string.concat(base, ".hopContract")),
            stdJson.readAddress(json, string.concat(base, ".oftToken")),
            uint32(stdJson.readUint(json, string.concat(base, ".destEid")))
        );
    }

    /// @dev CCTP: additionalData = (uint32 destDomain, address tokenMessenger, uint256 maxFee, uint32 minFinalityThreshold)
    function _parseCCTP(TopUpFactory.TokenConfig memory config, string memory json, string memory base) internal view {
        config.bridgeAdapter = cctpAdapter;
        config.additionalData = abi.encode(
            uint32(stdJson.readUint(json, string.concat(base, ".destDomain"))),
            stdJson.readAddress(json, string.concat(base, ".tokenMessenger")),
            stdJson.readUint(json, string.concat(base, ".maxFee")),
            uint32(stdJson.readUint(json, string.concat(base, ".minFinalityThreshold")))
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //                  HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _getRecipient(string memory destChainId) internal view returns (address) {
        string memory file = string.concat(vm.projectRoot(), "/deployments/", getEnv(), "/", destChainId, "/deployments.json");
        if (!vm.exists(file)) revert(string.concat("No deployment for chain ", destChainId));
        string memory dep = vm.readFile(file);
        return stdJson.readAddress(dep, ".addresses.TopUpDest");
    }

    function _getArrayLength(string memory json, string memory path) internal pure returns (uint256) {
        bytes memory data = stdJson.parseRaw(json, path);
        uint256 len;
        assembly { len := mload(add(data, 0x40)) }
        return len;
    }
}
