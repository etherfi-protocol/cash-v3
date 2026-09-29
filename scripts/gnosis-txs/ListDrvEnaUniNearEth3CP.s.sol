// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { console } from "forge-std/console.sol";

import { TradingLens } from "../../src/trading-safe/TradingLens.sol";
import { GnosisHelpers } from "../utils/GnosisHelpers.sol";
import { Utils } from "../utils/Utils.sol";

/**
 * @notice Generates and fork-simulates the Ethereum 3CP bundle that lists DRV, ENA, UNI, and
 *         Rainbow Bridge eNEAR as supported production TradingLens assets.
 *
 * Usage:
 *   ENV=mainnet forge script scripts/gnosis-txs/ListDrvEnaUniNearEth3CP.s.sol \
 *     --rpc-url $MAINNET_RPC
 */
contract ListDrvEnaUniNearEth3CP is GnosisHelpers, Utils {
    address internal constant OPERATING_SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;
    address internal constant TRADING_LENS = 0x7135AD135Ec21ec765C1930E93DEB7DA9c27290C;

    address internal constant DRV = 0xB1D1eae60EEA9525032a6DCb4c1CE336a1dE71BE;
    address internal constant ENA = 0x57e114B691Db790C35207b2e685D4A43181e6061;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
    address internal constant NEAR = 0x85F17Cf997934a597031b2E18a9aB6ebD4B9f6a4;

    function run() external {
        require(block.chainid == 1, "must run on Ethereum");
        require(isEqualString(getEnv(), "mainnet"), "prod script: ENV must be mainnet (or unset)");

        TradingLens lens = TradingLens(TRADING_LENS);
        address[] memory tokens = _tokens();

        _checkPreconditions(lens, tokens);
        uint256 countBefore = lens.getSupportedTokens().length;

        string memory txs = _getGnosisHeader(vm.toString(block.chainid), addressToHex(OPERATING_SAFE));
        for (uint256 i = 0; i < tokens.length; ++i) {
            bytes memory data = abi.encodeCall(TradingLens.addSupportedToken, (tokens[i]));
            txs = string.concat(txs, _getGnosisTransaction(addressToHex(TRADING_LENS), iToHex(data), "0", i == tokens.length - 1));
        }

        vm.createDir("./output", true);
        string memory path = "./output/ListDrvEnaUniNear3CP-eth-1.json";
        vm.writeFile(path, txs);
        console.log("Written: %s", path);

        executeGnosisTransactionBundle(path);

        for (uint256 i = 0; i < tokens.length; ++i) {
            require(lens.isSupportedToken(tokens[i]), "listed token missing");
        }
        require(lens.getSupportedTokens().length == countBefore + tokens.length, "lens count did not increase by four");

        console.log("Simulation passed. Tokens added: %s", tokens.length);
        console.log("Lens allowlist: %s", lens.getSupportedTokens().length);
    }

    function _checkPreconditions(TradingLens lens, address[] memory tokens) internal view {
        require(TRADING_LENS.code.length > 0, "TradingLens not deployed");
        require(lens.roleRegistry().hasRole(lens.TRADING_LENS_ADMIN_ROLE(), OPERATING_SAFE), "OperatingSafe lacks TRADING_LENS_ADMIN_ROLE");

        string[4] memory symbols = ["DRV", "ENA", "UNI", "NEAR"];
        uint8[4] memory decimals = [uint8(18), 18, 18, 24];
        for (uint256 i = 0; i < tokens.length; ++i) {
            require(tokens[i].code.length > 0, "token has no code");
            require(keccak256(bytes(IERC20Metadata(tokens[i]).symbol())) == keccak256(bytes(symbols[i])), "unexpected token symbol");
            require(IERC20Metadata(tokens[i]).decimals() == decimals[i], "unexpected token decimals");
            require(!lens.isSupportedToken(tokens[i]), "token already listed");
        }
    }

    function _tokens() internal pure returns (address[] memory tokens) {
        tokens = new address[](4);
        tokens[0] = DRV;
        tokens[1] = ENA;
        tokens[2] = UNI;
        tokens[3] = NEAR;
    }
}
