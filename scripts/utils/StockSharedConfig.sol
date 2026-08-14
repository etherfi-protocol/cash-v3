// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EtherFiDeployerHelper } from "./EtherFiDeployerHelper.sol";

/**
 * @title StockSharedConfig
 * @author ether.fi
 * @notice The handful of constants the two xStock rails genuinely share: the prod Safe, the
 *         LayerZero endpoint IDs, the destination chain id and the ENV switch.
 * @dev Exists so `StockWithdrawConfig` (withdraw direction, OP -> Ethereum) and
 *      `StockTopupConfig` (top-up direction, Ethereum -> OP) can be inherited by the SAME script.
 *      They previously each declared these members, which made that a duplicate-declaration
 *      error — and the Ethereum 3CP needs both halves in one bundle, because the Safe owns the
 *      Ethereum RoleRegistry and every privileged Ethereum call is a direct Safe call.
 *
 *      Deliberately NOT shared: the per-direction LayerZero gas limits. They are the same number
 *      today but different knobs — one is stored in the module's own state, the other in the
 *      TopUpFactory token config — and merging them would tie two independent tuning decisions
 *      together.
 */
abstract contract StockSharedConfig is EtherFiDeployerHelper {
    /// @notice Prod Safe (OperatingSafe). Holds the admin roles, and owns the Ethereum
    ///         RoleRegistry; on OP the registry owner is the 8h EtherFiTimelock instead.
    address internal constant SAFE = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /// @notice Optimism mainnet endpoint ID.
    uint32 internal constant OP_EID = 30111;
    /// @notice Ethereum mainnet endpoint ID.
    uint32 internal constant ETHEREUM_EID = 30101;
    /// @notice Optimism chain ID.
    uint256 internal constant OP_CHAIN_ID = 10;

    /// @dev True when ENV=dev; picks salts, admin addresses and the privileged-call path.
    function _isDev() internal view returns (bool) {
        return isEqualString(getEnv(), "dev");
    }
}
