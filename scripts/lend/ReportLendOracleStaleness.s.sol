// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IAaveV4Spoke } from "../../src/interfaces/IAaveV4Spoke.sol";
import { IAggregatorV3 } from "../../src/interfaces/IAggregatorV3.sol";
import { IOracleSink } from "../../src/interfaces/IOracleSink.sol";
import { IVedaAccountant } from "../../src/interfaces/IVedaAccountant.sol";
import { IPyth } from "../../src/oracle/PythPriceFeed.sol";

/// @dev The AaveOracle slice: reserves are priced through a per-reserve source it holds.
interface IAaveOracleLike {
    function decimals() external view returns (uint8);
    function getReserveSource(uint256 reserveId) external view returns (address);
    function getReservePrice(uint256 reserveId) external view returns (uint256);
}

/// @dev Common to every BaseAaveV4PriceFeed of ours; `underlyingUsdFeed` is the next leg down.
interface IOurFeedLike {
    function description() external view returns (string memory);
    function underlyingUsdFeed() external view returns (address);
}

interface IChainlinkFeedLike {
    function rateFeed() external view returns (address);
    function rateMaxStaleness() external view returns (uint256);
}

interface IVedaFeedLike {
    function accountant() external view returns (address);
    function rateMaxStaleness() external view returns (uint256);
}

interface ISinkFeedLike {
    function sink() external view returns (address);
    function token() external view returns (address);
    function rateMaxStaleness() external view returns (uint256);
}

interface IPythFeedLike {
    function pyth() external view returns (address);
    function oracle() external view returns (address);
    function maxStaleness() external view returns (uint256);
    function baseFeedId1() external view returns (bytes32);
    function baseFeedId2() external view returns (bytes32);
    function quoteFeedId1() external view returns (bytes32);
    function quoteFeedId2() external view returns (bytes32);
}

/// @dev Aave's growth-capped adapter (CLRatePriceCapAdapter and friends)
interface ICapoGrowthLike {
    function BASE_TO_USD_AGGREGATOR() external view returns (address);
    function RATIO_PROVIDER() external view returns (address);
    function isCapped() external view returns (bool);
}

/// @dev Aave's par-capped stable adapter
interface ICapoStableLike {
    function ASSET_TO_USD_AGGREGATOR() external view returns (address);
    function isCapped() external view returns (bool);
}

/**
 * @title ReportLendOracleStaleness
 * @notice Read-only staleness report for every reserve on the prod Summer Lend (Aave v4) Spoke.
 *
 *         For each listed reserve it reads the live price source from the Spoke's AaveOracle (NOT
 *         from summer-lend-feeds.json, so a repointed reserve or a capo adapter swapped in front of
 *         our feed is caught), then walks the source chain to the raw data legs and, for every leg
 *         that carries a staleness bound, prints the observed age, the bound, and the headroom left
 *         before `latestAnswer()` starts reverting with StalePrice.
 *
 *         Leg shapes understood: our ChainlinkPriceFeed / PythPriceFeed / VedaAccountantPriceFeed /
 *         OracleSinkPriceFeed, Aave's growth and stable price cap adapters, and a bare Chainlink
 *         aggregator (reported with its age but no bound, since nothing enforces one there).
 *
 *         Ages are measured against the latest block's timestamp, which is what the chain itself
 *         compares against — not wall-clock time.
 *
 *         Nothing is broadcast and no state is touched.
 *
 * Usage:
 *   source .env && forge script scripts/lend/ReportLendOracleStaleness.s.sol:ReportLendOracleStaleness \
 *     --rpc-url $OPTIMISM_RPC -v
 *
 * Optional env:
 *   SPOKE     override the Spoke address (defaults to deployments/mainnet/10/summer-lend.json .spoke)
 *   WARN_BPS  warn when remaining headroom is below this share of the bound (default 2500 = 25%)
 */
contract ReportLendOracleStaleness is Script {
    uint256 internal constant BPS = 10_000;

    uint256 internal warnBps;
    uint256 internal staleLegs;
    uint256 internal warnLegs;
    uint256 internal unboundedLegs;
    string[] internal problems;

    function run() public {
        require(block.chainid == 10, "Optimism only");
        warnBps = vm.envOr("WARN_BPS", uint256(2500));

        address spokeAddr = vm.envOr("SPOKE", address(0));
        if (spokeAddr == address(0)) {
            string memory path = string.concat(vm.projectRoot(), "/deployments/mainnet/10/summer-lend.json");
            require(vm.exists(path), "deployments/mainnet/10/summer-lend.json missing");
            spokeAddr = stdJson.readAddress(vm.readFile(path), ".spoke");
        }
        require(spokeAddr.code.length != 0, "spoke has no code");

        IAaveV4Spoke spoke = IAaveV4Spoke(spokeAddr);
        IAaveOracleLike oracle = IAaveOracleLike(spoke.ORACLE());
        uint256 count = spoke.getReserveCount();

        console.log("Spoke:      ", spokeAddr);
        console.log("AaveOracle: ", address(oracle));
        console.log("Block ts:   ", block.timestamp);
        console.log("Reserves:   ", count);
        console.log("Warn below: ", string.concat(vm.toString(warnBps / 100), "% headroom"));
        console.log("");

        for (uint256 id = 0; id < count; ++id) {
            _reportReserve(spoke, oracle, id);
        }

        console.log("================================================================");
        console.log(string.concat("STALE legs: ", vm.toString(staleLegs), "  |  WARN legs: ", vm.toString(warnLegs), "  |  unbounded legs: ", vm.toString(unboundedLegs)));
        for (uint256 i = 0; i < problems.length; ++i) {
            console.log(string.concat("  - ", problems[i]));
        }
        if (problems.length == 0) console.log("  every bounded leg is fresh");
    }

    // ─────────────────────────────── per reserve ───────────────────────────────

    function _reportReserve(IAaveV4Spoke spoke, IAaveOracleLike oracle, uint256 id) internal {
        IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(id);
        string memory symbol = _symbolOf(reserve.underlying);

        address source;
        try oracle.getReserveSource(id) returns (address s) {
            source = s;
        } catch {
            console.log(string.concat("[", vm.toString(id), "] ", symbol, "  <getReserveSource reverted>"));
            _flag(string.concat(symbol, ": getReserveSource reverted"));
            return;
        }

        console.log(string.concat("[", vm.toString(id), "] ", symbol, "  underlying ", vm.toString(reserve.underlying)));
        console.log(string.concat("      source ", vm.toString(source)));

        // The end-to-end read the pool actually performs; a revert here is what breaks borrows,
        // withdrawals and liquidations for this reserve.
        try oracle.getReservePrice(id) returns (uint256 price) {
            console.log(string.concat("      price  ", vm.toString(price), "   LIVE"));
        } catch Error(string memory reason) {
            console.log(string.concat("      price  REVERTED: ", reason));
            _flag(string.concat(symbol, ": getReservePrice reverted (", reason, ")"));
        } catch (bytes memory err) {
            console.log(string.concat("      price  REVERTED: ", _errName(err)));
            _flag(string.concat(symbol, ": getReservePrice reverted (", _errName(err), ")"));
        }

        _walk(symbol, source, "      -> ", 0);
        console.log("");
    }

    // ─────────────────────────────── source walk ───────────────────────────────

    /// @dev Prints one node of the price-source chain and recurses into its legs.
    function _walk(string memory symbol, address node, string memory pad, uint256 depth) internal {
        if (node == address(0)) return;
        if (depth > 6) {
            console.log(string.concat(pad, "<depth limit>"));
            return;
        }
        if (node.code.length == 0) {
            console.log(string.concat(pad, vm.toString(node), " has NO CODE"));
            _flag(string.concat(symbol, ": source leg ", vm.toString(node), " has no code"));
            return;
        }

        string memory nextPad = string.concat(pad, "  ");

        // Aave growth cap adapter
        try ICapoGrowthLike(node).BASE_TO_USD_AGGREGATOR() returns (address base) {
            address ratioProvider;
            try ICapoGrowthLike(node).RATIO_PROVIDER() returns (address r) { ratioProvider = r; } catch { }
            string memory capped = "capped?=unknown";
            try ICapoGrowthLike(node).isCapped() returns (bool c) { capped = c ? "CAPPED (price is being clamped)" : "not capped"; } catch { }
            console.log(string.concat(pad, "CAPO growth adapter ", vm.toString(node), "  ", capped));
            if (_startsWithCapped(capped)) _flag(string.concat(symbol, ": capo adapter ", vm.toString(node), " is currently capping the price"));
            if (ratioProvider != address(0)) {
                console.log(string.concat(nextPad, "ratio provider ", vm.toString(ratioProvider)));
                _walk(symbol, ratioProvider, string.concat(nextPad, "  "), depth + 1);
            }
            _walk(symbol, base, nextPad, depth + 1);
            return;
        } catch { }

        // Aave stable (par) cap adapter
        try ICapoStableLike(node).ASSET_TO_USD_AGGREGATOR() returns (address asset) {
            string memory capped = "capped?=unknown";
            try ICapoStableLike(node).isCapped() returns (bool c) { capped = c ? "CAPPED (price is being clamped)" : "not capped"; } catch { }
            console.log(string.concat(pad, "CAPO stable adapter ", vm.toString(node), "  ", capped));
            if (_startsWithCapped(capped)) _flag(string.concat(symbol, ": capo adapter ", vm.toString(node), " is currently capping the price"));
            _walk(symbol, asset, nextPad, depth + 1);
            return;
        } catch { }

        // our ChainlinkPriceFeed
        try IChainlinkFeedLike(node).rateFeed() returns (address rateFeed) {
            uint256 bound = IChainlinkFeedLike(node).rateMaxStaleness();
            console.log(string.concat(pad, "ChainlinkPriceFeed ", vm.toString(node), "  \"", _desc(node), "\""));
            uint256 updatedAt;
            bool ok;
            try IAggregatorV3(rateFeed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 u, uint80) {
                updatedAt = u;
                ok = true;
                if (answer <= 0) _flag(string.concat(symbol, ": aggregator ", vm.toString(rateFeed), " reports non-positive answer"));
            } catch {
                _flag(string.concat(symbol, ": aggregator ", vm.toString(rateFeed), " latestRoundData reverted"));
            }
            if (ok) _leg(symbol, nextPad, string.concat("chainlink aggregator ", vm.toString(rateFeed)), updatedAt, bound);
            else console.log(string.concat(nextPad, "chainlink aggregator ", vm.toString(rateFeed), "  READ FAILED"));
            _walkUnderlying(symbol, node, nextPad, depth);
            return;
        } catch { }

        // our VedaAccountantPriceFeed
        try IVedaFeedLike(node).accountant() returns (address accountant) {
            uint256 bound = IVedaFeedLike(node).rateMaxStaleness();
            console.log(string.concat(pad, "VedaAccountantPriceFeed ", vm.toString(node), "  \"", _desc(node), "\""));
            try IVedaAccountant(accountant).accountantState() returns (IVedaAccountant.AccountantState memory st) {
                if (st.isPaused) {
                    console.log(string.concat(nextPad, "accountant ", vm.toString(accountant), "  PAUSED"));
                    _flag(string.concat(symbol, ": Veda accountant ", vm.toString(accountant), " is PAUSED"));
                }
                if (st.exchangeRate == 0) _flag(string.concat(symbol, ": Veda accountant ", vm.toString(accountant), " exchangeRate is 0"));
                _leg(symbol, nextPad, string.concat("veda accountant ", vm.toString(accountant)), st.lastUpdateTimestamp, bound);
            } catch {
                console.log(string.concat(nextPad, "accountant ", vm.toString(accountant), "  READ FAILED"));
                _flag(string.concat(symbol, ": Veda accountant ", vm.toString(accountant), " accountantState reverted"));
            }
            _walkUnderlying(symbol, node, nextPad, depth);
            return;
        } catch { }

        // our OracleSinkPriceFeed
        try ISinkFeedLike(node).sink() returns (address sink) {
            address tok = ISinkFeedLike(node).token();
            uint256 bound = ISinkFeedLike(node).rateMaxStaleness();
            console.log(string.concat(pad, "OracleSinkPriceFeed ", vm.toString(node), "  \"", _desc(node), "\""));
            try IOracleSink(sink).latestRoundData(tok) returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
                if (answer <= 0) _flag(string.concat(symbol, ": sink ", vm.toString(sink), " reports non-positive answer"));
                _leg(symbol, nextPad, string.concat("relayed sink ", vm.toString(sink), " key ", vm.toString(tok)), updatedAt, bound);
            } catch {
                console.log(string.concat(nextPad, "sink ", vm.toString(sink), " key ", vm.toString(tok), "  READ FAILED (never relayed?)"));
                _flag(string.concat(symbol, ": OracleSink ", vm.toString(sink), " has no price for ", vm.toString(tok)));
            }
            _walkUnderlying(symbol, node, nextPad, depth);
            return;
        } catch { }

        // our PythPriceFeed
        try IPythFeedLike(node).pyth() returns (address pyth) {
            uint256 bound = IPythFeedLike(node).maxStaleness();
            console.log(string.concat(pad, "PythPriceFeed ", vm.toString(node), "  \"", _desc(node), "\""));
            _pythLeg(symbol, nextPad, pyth, IPythFeedLike(node).baseFeedId1(), bound, "base1");
            _pythLeg(symbol, nextPad, pyth, IPythFeedLike(node).baseFeedId2(), bound, "base2");
            _pythLeg(symbol, nextPad, pyth, IPythFeedLike(node).quoteFeedId1(), bound, "quote1");
            _pythLeg(symbol, nextPad, pyth, IPythFeedLike(node).quoteFeedId2(), bound, "quote2");
            _walkUnderlying(symbol, node, nextPad, depth);
            return;
        } catch { }

        // Anything else: a bare aggregator, a Midas proxy, a rate provider. Report its age if it has
        // one, but nothing at this level enforces a bound.
        try IAggregatorV3(node).latestRoundData() returns (uint80, int256, uint256, uint256 updatedAt, uint80) {
            unboundedLegs++;
            console.log(string.concat(pad, "raw aggregator ", vm.toString(node), "  age ", _dur(_age(updatedAt)), "  (no bound enforced at this level)"));
        } catch {
            console.log(string.concat(pad, "unrecognized source ", vm.toString(node)));
        }
    }

    function _walkUnderlying(string memory symbol, address node, string memory pad, uint256 depth) internal {
        try IOurFeedLike(node).underlyingUsdFeed() returns (address u) {
            if (u != address(0)) _walk(symbol, u, pad, depth + 1);
        } catch { }
    }

    function _pythLeg(string memory symbol, string memory pad, address pyth, bytes32 feedId, uint256 bound, string memory slot) internal {
        if (feedId == bytes32(0)) return;
        try IPyth(pyth).getPriceUnsafe(feedId) returns (IPyth.Price memory p) {
            _leg(symbol, pad, string.concat("pyth ", slot, " ", vm.toString(feedId)), p.publishTime, bound);
        } catch {
            console.log(string.concat(pad, "pyth ", slot, " ", vm.toString(feedId), "  READ FAILED"));
            _flag(string.concat(symbol, ": Pyth feed ", vm.toString(feedId), " read failed"));
        }
    }

    // ─────────────────────────────── staleness math ───────────────────────────────

    /// @dev Prints one bounded leg and books it as STALE / WARN / OK.
    function _leg(string memory symbol, string memory pad, string memory label, uint256 updatedAt, uint256 bound) internal {
        uint256 age = _age(updatedAt);
        // Mirrors the feeds' own check: `block.timestamp > updatedAt + bound` reverts.
        bool stale = block.timestamp > updatedAt + bound;
        uint256 headroom = stale ? 0 : (updatedAt + bound) - block.timestamp;
        bool warn = !stale && bound > 0 && headroom * BPS < bound * warnBps;

        string memory verdict = stale ? "STALE" : (warn ? "WARN " : "OK   ");
        console.log(string.concat(pad, verdict, " ", label));
        console.log(string.concat(pad, "        age ", _dur(age), " / max ", _dur(bound), "   headroom ", stale ? "0 (EXPIRED)" : _dur(headroom)));

        if (stale) {
            staleLegs++;
            _flag(string.concat(symbol, ": STALE - ", label, " age ", _dur(age), " > max ", _dur(bound)));
        } else if (warn) {
            warnLegs++;
            _flag(string.concat(symbol, ": low headroom - ", label, " has ", _dur(headroom), " of ", _dur(bound), " left"));
        }
    }

    function _age(uint256 updatedAt) internal view returns (uint256) {
        // A future-dated timestamp is not staleness; report it as zero age rather than underflowing.
        return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    }

    function _flag(string memory s) internal {
        problems.push(s);
    }

    // ─────────────────────────────── formatting ───────────────────────────────

    function _dur(uint256 s) internal pure returns (string memory) {
        if (s < 60) return string.concat(_u(s), "s");
        if (s < 3600) return string.concat(_u(s / 60), "m", _u((s % 60)), "s");
        if (s < 86_400) return string.concat(_u(s / 3600), "h", _u((s % 3600) / 60), "m");
        return string.concat(_u(s / 86_400), "d", _u((s % 86_400) / 3600), "h");
    }

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) ++len;
        bytes memory b = new bytes(len);
        for (uint256 i = len; i > 0; --i) {
            b[i - 1] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return string(b);
    }

    function _desc(address feed) internal view returns (string memory) {
        try IOurFeedLike(feed).description() returns (string memory d) { return d; }
        catch { return "?"; }
    }

    function _symbolOf(address token) internal view returns (string memory) {
        try IERC20Metadata(token).symbol() returns (string memory s) { return s; }
        catch { return vm.toString(token); }
    }

    /// @dev Maps the 4-byte custom errors our feeds revert with to readable names.
    function _errName(bytes memory err) internal pure returns (string memory) {
        if (err.length < 4) return "no revert data";
        bytes4 sel = bytes4(err[0]) | (bytes4(err[1]) >> 8) | (bytes4(err[2]) >> 16) | (bytes4(err[3]) >> 24);
        if (sel == bytes4(keccak256("StalePrice()"))) return "StalePrice()";
        if (sel == bytes4(keccak256("InvalidPrice()"))) return "InvalidPrice()";
        if (sel == bytes4(keccak256("AccountantPaused()"))) return "AccountantPaused()";
        return "unknown selector";
    }

    /// @dev True when the isCapped read came back as the "CAPPED ..." string built above.
    function _startsWithCapped(string memory s) private pure returns (bool) {
        bytes memory b = bytes(s);
        return b.length > 6 && b[0] == "C" && b[1] == "A" && b[2] == "P";
    }
}
