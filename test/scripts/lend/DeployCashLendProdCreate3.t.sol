// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

import { DeployCashLendProd } from "../../../scripts/lend/DeployCashLendProd.s.sol";
import { VerifyCashLendProd } from "../../../scripts/lend/VerifyCashLendProd.s.sol";
import { EtherFiDeployer } from "../../../src/utils/EtherFiDeployer.sol";

/// @dev Exposes the deploy script's address derivation without broadcasting anything.
contract DeployCashLendProdHarness is DeployCashLendProd {
    function predicted(string memory name) external pure returns (address) {
        return _predicted(name);
    }

    /// @dev Named `saltFor` because GnosisHelpers already declares a `salt` constant.
    function saltFor(string memory name) external pure returns (bytes32) {
        return _salt(name);
    }

    function deployerAddress() external pure returns (address) {
        return ETHERFI_DEPLOYER;
    }
}

/// @dev Exposes the verification script's address derivation.
contract VerifyCashLendProdHarness is VerifyCashLendProd {
    function predicted(string memory name) external pure returns (address) {
        return _predicted(name);
    }
}

/// @dev Stand-in for Nick's factory: a CREATE2 deployer that takes `salt ++ initCode` from anyone.
///      Behaviourally identical to the real one for the purposes of this test.
contract PermissionlessCreate2Factory {
    fallback() external payable {
        assembly {
            let size := sub(calldatasize(), 0x20)
            calldatacopy(0x00, 0x00, 0x20)
            let s := mload(0x00)
            calldatacopy(0x00, 0x20, size)
            let addr := create2(callvalue(), 0x00, size, s)
            if iszero(addr) { revert(0x00, 0x00) }
            mstore(0x00, addr)
            return(0x0c, 0x14)
        }
    }
}

/// @dev Bytecode an attacker would park at a squatted address.
contract Squatter {
    function pwned() external pure returns (bool) {
        return true;
    }
}

/**
 * @title DeployCashLendProdCreate3Test
 * @notice Guards the property that makes DeployCashLendProd's skip-if-already-deployed branch safe:
 *         every `CashLendProd.*` address must derive from the protocol's PERMISSIONED CREATE3
 *         deployer. The salts are public (this repo is public), so under a public factory anyone
 *         could park bytecode at those addresses and the deploy script would wire it into the prod
 *         Safe bundle as an implementation. test_publicFactoryLetsAnyoneSquatAPublicSalt below
 *         demonstrates exactly that failure mode against a permissionless factory.
 */
contract DeployCashLendProdCreate3Test is Test {
    DeployCashLendProdHarness internal deployScript;
    VerifyCashLendProdHarness internal verifyScript;

    /// @dev Every salt name the deploy script derives an address for.
    string[23] internal NAMES = [
        "CashModuleCoreImpl",
        "CashModuleSettersImpl",
        "CashLensImpl",
        "CashEventEmitterImpl",
        "DebtManagerCoreImpl",
        "DebtManagerAdminImpl",
        "EtherFiHookImpl",
        "TopUpDestImpl",
        "LiquifierImpl",
        "EnsoImpl",
        "AcrossImpl",
        "EtherFiSafeImpl",
        "LendGatewayImpl",
        "LendGatewayProxy",
        "AaveV4LensImpl",
        "AaveV4LensProxy",
        "OpenOceanModule",
        "LiquidModule",
        "LiquidReferrerModule",
        "FraxModule",
        "StakeModule",
        "MidasModule",
        "BeHYPEModule"
    ];

    function setUp() public {
        deployScript = new DeployCashLendProdHarness();
        verifyScript = new VerifyCashLendProdHarness();
    }

    /// @dev The deploy and verify scripts must never drift apart: the verifier's whole hijack check
    ///      is "the impl slot holds the address I predict", which is worthless if it predicts
    ///      addresses from a different deployer than the one that deployed them. Both inherit
    ///      CashLendProdConfig today; this fails the moment either one re-declares its own
    ///      derivation, and pins every address to the permissioned deployer rather than Nick's.
    function test_bothScriptsPredictFromThePermissionedDeployer() public view {
        address nicks = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        for (uint256 i = 0; i < NAMES.length; ++i) {
            address expected = deployScript.predicted(NAMES[i]);
            assertEq(expected, verifyScript.predicted(NAMES[i]), NAMES[i]);
            assertEq(expected, CREATE3.predictDeterministicAddress(deployScript.saltFor(NAMES[i]), deployScript.deployerAddress()), NAMES[i]);
            assertTrue(expected != CREATE3.predictDeterministicAddress(deployScript.saltFor(NAMES[i]), nicks), NAMES[i]);
        }
    }

    /// @dev Proves the scripts' derivation formula matches what EtherFiDeployer actually produces —
    ///      not just that the two scripts agree with each other.
    function test_predictionMatchesWhatThePermissionedDeployerProduces() public {
        address authorised = makeAddr("authorised");
        address[] memory initial = new address[](1);
        initial[0] = authorised;
        EtherFiDeployer deployer = new EtherFiDeployer(address(this), initial);

        bytes32 gatewaySalt = deployScript.saltFor("LendGatewayProxy");

        vm.prank(authorised);
        address deployed = deployer.deploy(gatewaySalt, type(Squatter).creationCode);

        assertEq(deployed, CREATE3.predictDeterministicAddress(gatewaySalt, address(deployer)), "formula mismatch");
        assertEq(deployed, deployer.getDeterministicAddress(gatewaySalt), "deployer disagrees with itself");
        assertTrue(Squatter(deployed).pwned());
    }

    /// @dev The core guarantee: an outsider cannot occupy one of our addresses, so code already
    ///      sitting at a predicted address can only have been put there by a registered deployer.
    function test_unregisteredCallerCannotDeploy() public {
        EtherFiDeployer deployer = new EtherFiDeployer(address(this), new address[](0));
        // Resolve the salt BEFORE pranking — an intervening call would consume the prank.
        bytes32 implSalt = deployScript.saltFor("CashModuleCoreImpl");

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(EtherFiDeployer.OnlyDeployer.selector);
        deployer.deploy(implSalt, type(Squatter).creationCode);
    }

    /// @dev Regression rationale — do NOT move these deployments back onto a public factory. With a
    ///      permissionless CREATE2 factory the published salt is enough for anyone to place code of
    ///      their choosing at the exact address the scripts predict.
    function test_publicFactoryLetsAnyoneSquatAPublicSalt() public {
        PermissionlessCreate2Factory factory = new PermissionlessCreate2Factory();
        bytes32 implSalt = deployScript.saltFor("CashModuleCoreImpl");
        address target = CREATE3.predictDeterministicAddress(implSalt, address(factory));
        assertEq(target.code.length, 0, "precondition: address is vacant");

        // Anyone at all — no relationship to the protocol.
        vm.startPrank(makeAddr("attacker"));
        (bool ok,) = address(factory).call(abi.encodePacked(implSalt, hex"67363d3d37363d34f03d5260086018f3"));
        assertTrue(ok, "CREATE3 proxy deploy");
        address proxy = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(factory), implSalt, CREATE3.PROXY_INITCODE_HASH)))));
        (ok,) = proxy.call(type(Squatter).creationCode);
        assertTrue(ok, "squat deploy");
        vm.stopPrank();

        // The address a deploy script would have predicted now holds attacker-chosen bytecode, and
        // `target.code.length > 0` — the old skip condition — reads as "already deployed by us".
        assertGt(target.code.length, 0);
        assertTrue(Squatter(target).pwned(), "attacker controls the predicted address");
    }
}
