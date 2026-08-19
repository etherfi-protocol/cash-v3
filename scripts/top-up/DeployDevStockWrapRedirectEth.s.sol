// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { console } from "forge-std/console.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { IRoleRegistry } from "../../src/interfaces/IRoleRegistry.sol";
import { ITradingSafeFactory } from "../../src/interfaces/ITradingSafeFactory.sol";
import { TopUp } from "../../src/top-up/TopUp.sol";
import { TopUpFactory } from "../../src/top-up/TopUpFactory.sol";
import { Utils } from "../utils/Utils.sol";
import { StockRedirectWrappers } from "./StockRedirectWrappers.sol";

/**
 * @title DeployDevStockWrapRedirectEth
 * @notice Rolls the raw-xStock redirect wrapping onto the Ethereum **dev** stack: upgrades the dev
 *         `TopUpFactory` and its `TopUp` beacon to the implementations that carry it, then
 *         registers the 90 raw-stock → wrapper pairs the dev `TradingLens` actually lists.
 *
 * @dev Ordering inside the broadcast is load-bearing, and is why this is one script rather than
 *      three: a new `TopUp` impl asks its owner for `wrapperFor(token)`, so a beacon upgraded
 *      ahead of the factory would revert every redirect from all 81 dev TopUps until the factory
 *      caught up. Factory first, beacon second, configuration last — the last of which is inert
 *      until both impls are live, so the window where the stack is half-upgraded closes inside a
 *      single broadcast.
 *
 *      Every pair is checked against the chain before anything is broadcast: the wrapper must be
 *      an ERC-4626 over the very raw token it is paired with, must be listed on the dev trading
 *      lens (it is the form the safe ends up holding), and the raw token must NOT be topup-
 *      supported — a token with a bridge route of its own belongs in `processTopUp`, and the
 *      redirect would reject it anyway. `setRedirectWrappers` re-checks the `asset()` pairing
 *      on-chain regardless; the preflight only moves the failure before the broadcast.
 *
 *      Collateral stocks are out of scope by construction: wSPYx is not on the dev lens, and
 *      wQQQx / wTBLLx are excluded from the generated pair list. See
 *      `StockRedirectWrappers.sol` for how the list is derived and reproduced.
 *
 * Usage (simulate by dropping --broadcast; the wallet must be the dev RoleRegistry OWNER — the
 * factory upgrade, the beacon upgrade and `setRedirectWrappers` are all owner-gated):
 *   source .env && ENV=dev forge script \
 *     scripts/top-up/DeployDevStockWrapRedirectEth.s.sol:DeployDevStockWrapRedirectEth \
 *     --rpc-url $MAINNET_RPC --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY -vvv
 */
contract DeployDevStockWrapRedirectEth is Utils {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function run() public {
        require(block.chainid == 1, "must run on Ethereum (1)");
        require(isEqualString(getEnv(), "dev"), "dev-only: targets the dev TopUpFactory and dev TradingLens");

        string memory deployments = readTopUpSourceDeployment();
        TopUpFactory factory = TopUpFactory(payable(stdJson.readAddress(deployments, ".addresses.TopUpSourceFactory")));
        IRoleRegistry roleRegistry = IRoleRegistry(stdJson.readAddress(deployments, ".addresses.RoleRegistry"));

        address sender = vm.addr(vm.envUint("PRIVATE_KEY"));
        require(roleRegistry.owner() == sender, "sender is not the dev RoleRegistry owner");

        (address[] memory raws, address[] memory wrappers) = StockRedirectWrappers.pairs();
        _preflight(factory, raws, wrappers);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // 1. Factory first — it is what every TopUp reads `wrapperFor` off.
        address factoryImpl = address(new TopUpFactory());
        UUPSUpgradeable(address(factory)).upgradeToAndCall(factoryImpl, "");

        // 2. Then the beacon, so no TopUp ever calls a factory that can't answer.
        address topUpImpl = address(new TopUp(WETH));
        factory.upgradeBeaconImplementation(topUpImpl);

        // 3. Configuration last: inert until both of the above are live.
        factory.setRedirectWrappers(raws, wrappers);

        vm.stopBroadcast();

        _assertPostState(factory, raws, wrappers);

        console.log("TopUpFactory impl :", factoryImpl);
        console.log("TopUp impl        :", topUpImpl);
        console.log("wrappers registered:", raws.length);
    }

    /// @dev Fails before the broadcast on anything the chain disagrees with.
    function _preflight(TopUpFactory factory, address[] memory raws, address[] memory wrappers) internal view {
        address tsFactory = factory.tradingSafeFactory();
        require(tsFactory != address(0), "tradingSafeFactory not set on the dev TopUpFactory");

        for (uint256 i = 0; i < raws.length; ++i) {
            require(raws[i].code.length > 0, "raw stock has no code");
            require(wrappers[i].code.length > 0, "wrapper has no code");
            require(IERC4626(wrappers[i]).asset() == raws[i], "wrapper is not the ERC-4626 over its raw stock");
            require(ITradingSafeFactory(tsFactory).isSupportedToken(wrappers[i]), "wrapper is not trading-supported on the dev lens");
            require(!factory.isTokenSupported(raws[i]), "raw stock is topup-supported: it belongs in processTopUp");
        }
    }

    function _assertPostState(TopUpFactory factory, address[] memory raws, address[] memory wrappers) internal view {
        for (uint256 i = 0; i < raws.length; ++i) {
            require(factory.wrapperFor(raws[i]) == wrappers[i], "redirect wrapper not registered");
        }
        // A token with no configured wrapper still redirects as-is.
        require(factory.wrapperFor(WETH) == address(0), "unexpected wrapper on an unconfigured token");
    }
}
