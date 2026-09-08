// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { EtherFiDeployerHelper } from "./utils/EtherFiDeployerHelper.sol";

/**
 * @title CashbackDistributorConfig
 * @author ether.fi
 * @notice Constants and CREATE3 salts shared by DeployCashbackDistributor and
 *         VerifyCashbackDistributor, so the verifier predicts the exact addresses the
 *         deployer creates. Everything here is Optimism (chain 10): both cash envs (dev and
 *         mainnet) live on OP mainnet and share the same token/teller addresses; only the
 *         salts (and the deployments.json the RoleRegistry/DataProvider are read from) are
 *         env-scoped.
 */
abstract contract CashbackDistributorConfig is EtherFiDeployerHelper {
    /// @notice ETHFI token on Optimism.
    address internal constant ETHFI = 0xe0080d2F853ecDdbd81A643dC10DA075Df26fD3f;

    /// @notice sETHFI liquid-vault share token on Optimism.
    address internal constant SETHFI = 0x86B5780b606940Eb59A062aA85a07959518c0161;

    /// @notice BoringVault-style teller staking ETHFI into sETHFI on Optimism, passed to
    ///         `initialize` so `awardStaked` is live from the proxy's first block. The
    ///         initializer validates it (vault match, zero share lock) and the whole CREATE3
    ///         deploy reverts if it doesn't pass.
    address internal constant SETHFI_TELLER = 0x35dD2463fA7a335b721400C5Ad8Ba40bD85c179b;

    function _implSalt() internal view returns (string memory) {
        return string.concat(_saltPrefix(), ".Cashback.CashbackDistributorImpl");
    }

    function _proxySalt() internal view returns (string memory) {
        return string.concat(_saltPrefix(), ".Cashback.CashbackDistributorProxy");
    }

    function _saltPrefix() internal view returns (string memory) {
        return _isDev() ? "Dev" : "Prod";
    }

    /// @dev True when ENV=dev; picks the salt prefix and whether privileged calls (grantRole)
    ///      can be broadcast directly — on prod the RoleRegistry owner is the timelock, so
    ///      grants ship as a separate gnosis-txs bundle instead.
    function _isDev() internal view returns (bool) {
        return isEqualString(getEnv(), "dev");
    }
}
