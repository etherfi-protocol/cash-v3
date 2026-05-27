// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { ContractCodeChecker } from "./utils/ContractCodeChecker.sol";
import { Utils } from "./utils/Utils.sol";

import { OneInchSwapModule } from "../src/modules/oneinch-swap/OneInchSwapModule.sol";
import { EtherFiSafe } from "../src/safe/EtherFiSafe.sol";
import { EtherFiDataProvider } from "../src/data-provider/EtherFiDataProvider.sol";
import { DebtManagerCore } from "../src/debt-manager/DebtManagerCore.sol";

/// @title Bytecode verification for the 1inch deployment (OP mainnet)
/// @notice Re-deploys each impl locally with the same constructor args and diffs runtime bytecode
///         against the on-chain deployment (CBOR metadata trimmed).
///
///         The three UUPS impls (OneInchSwapModule, EtherFiDataProvider, DebtManagerCore) embed
///         `UUPSUpgradeable.__self = address(this)` as an immutable. That value is, by definition,
///         the contract's own deployed address, so it differs between the on-chain impl and a fresh
///         local re-deploy and would otherwise show as a spurious mismatch. We neutralise it by
///         zeroing each contract's own address wherever it appears before comparing. EtherFiSafe is
///         a beacon impl (not UUPS) so it has no such immutable and matches byte-for-byte.
///
///         The deployed addresses default to the OP mainnet `Deploy.s.sol` run; override via env.
///
///         Usage:
///           source .env && ENV=mainnet \
///             forge script scripts/Verify1inchBytecode.s.sol --rpc-url optimism -vvv
contract Verify1inchBytecode is Script, ContractCodeChecker, Utils {
    /// Must match Deploy.s.sol exactly (baked into OneInchSwapModule immutables)
    address constant AGGREGATION_ROUTER   = 0x111111125421cA6dc452d289314280a0f8842A65;
    address constant SIMPLE_SETTLEMENT_OP = 0x2Ad5004c60e16E54d5007C80CE329Adde5B51Ef5;
    address constant OPERATING_SAFE       = 0xA6cf33124cb342D1c604cAC87986B965F428AAC4;

    /// Deployed by Deploy.s.sol on OP (defaults; override with the matching env vars).
    address constant ONE_INCH_MODULE_PROXY = 0xE6a499729200Da34655425364bB55D7EfA507318;
    address constant NEW_SAFE_IMPL         = 0xe33BE40c822ACF71dE7Fd253A19d74678104424c;
    address constant NEW_DATA_PROVIDER_IMPL= 0x57a8aceB7eBD2bDbce60C7a4F2C5dE8efd650Ba7;
    address constant NEW_DEBT_MANAGER_IMPL = 0x182Ad6b5855D77Ea87CBad05518573C3a7b4d789;

    bytes32 constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() public {
        string memory d = readDeploymentFile();
        address dataProvider = stdJson.readAddress(d, ".addresses.EtherFiDataProvider");

        address moduleProxy = vm.envOr("ONE_INCH_MODULE_PROXY", ONE_INCH_MODULE_PROXY);
        address newSafeImpl = vm.envOr("NEW_SAFE_IMPL", NEW_SAFE_IMPL);
        address newDpImpl   = vm.envOr("NEW_DATA_PROVIDER_IMPL", NEW_DATA_PROVIDER_IMPL);
        address newDmImpl   = vm.envOr("NEW_DEBT_MANAGER_IMPL", NEW_DEBT_MANAGER_IMPL);

        address moduleImpl = address(uint160(uint256(vm.load(moduleProxy, EIP1967_IMPL_SLOT))));

        console2.log("== 1inch bytecode verification ==");
        console2.log("dataProvider:", dataProvider);
        console2.log("module proxy:", moduleProxy);

        _verify("OneInchSwapModule", moduleImpl,
            address(new OneInchSwapModule(AGGREGATION_ROUTER, SIMPLE_SETTLEMENT_OP, dataProvider, OPERATING_SAFE)));
        _verify("EtherFiSafe", newSafeImpl, address(new EtherFiSafe(dataProvider)));
        _verify("EtherFiDataProvider", newDpImpl, address(new EtherFiDataProvider()));
        _verify("DebtManagerCore", newDmImpl, address(new DebtManagerCore(dataProvider)));

        console2.log("== all impls verified ==");
    }

    /// @dev Compares runtime bytecode after trimming CBOR metadata and zeroing each contract's own
    ///      address (the UUPS `__self` immutable). Reverts on any difference beyond that.
    function _verify(string memory name, address onchain, address localCopy) internal {
        bytes memory a = _blankSelf(trimMetadata(onchain.code), onchain);
        bytes memory b = _blankSelf(trimMetadata(localCopy.code), localCopy);

        console2.log("--", name, "--");
        console2.log("on-chain:", onchain);
        console2.log("local   :", localCopy);

        require(a.length == b.length, string.concat(name, ": length mismatch"));
        bool ok = keccak256(a) == keccak256(b);
        console2.log(ok ? "  MATCH (self-address immutable ignored)" : "  MISMATCH");
        require(ok, string.concat(name, ": bytecode differs beyond the self-address immutable"));
    }

    /// @dev Returns `code` with every 20-byte occurrence of `self` overwritten with zeros.
    function _blankSelf(bytes memory code, address self) internal pure returns (bytes memory) {
        bytes20 needle = bytes20(self);
        uint256 i;
        while (i + 20 <= code.length) {
            bool hit = true;
            for (uint256 j; j < 20; ++j) {
                if (code[i + j] != needle[j]) { hit = false; break; }
            }
            if (hit) {
                for (uint256 j; j < 20; ++j) code[i + j] = 0;
                i += 20;
            } else {
                unchecked { ++i; }
            }
        }
        return code;
    }
}
