// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Test } from "forge-std/Test.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { PaymentLinkModule } from "../../src/payment-link/PaymentLinkModule.sol";

/// @dev Just enough DataProvider for the module constructor's CashModule cross-check.
contract VectorDataProvider {
    address public immutable cashModule;

    constructor(address _cashModule) {
        cashModule = _cashModule;
    }

    function getCashModule() external view returns (address) {
        return cashModule;
    }
}

/**
 * @title PaymentLinkDigestVectorsTest
 * @notice Pins the three digests the off-chain builders must reproduce, as a JSON fixture at
 *         test/payment-link/fixtures/digest-vectors.json: `requestLinkDigest` and
 *         `cancelLinkDigest` (EIP-191 owner digests over the module's own per-safe nonce) and
 *         `claimDigest` (EIP-712, domain "EtherFi PaymentLinkModule" / "1"). The vectors use
 *         chain id 10 and the predicted dev and prod proxy addresses, and include a claim
 *         signature by a TEST-ONLY key (private keys 1, 2, 3) so the claim relay and the web
 *         signer can be checked end to end.
 * @dev No fork needed. Regenerate the fixture (only when the digest format intentionally
 *      changes) with:
 *        PAYMENT_LINK_WRITE_VECTORS=true forge test --match-path test/payment-link/PaymentLinkDigestVectors.t.sol
 */
contract PaymentLinkDigestVectorsTest is Test {
    using stdJson for string;
    using MessageHashUtils for bytes32;

    string internal constant FIXTURE = "test/payment-link/fixtures/digest-vectors.json";

    uint256 internal constant CHAIN_ID = 10;
    /// @dev CREATE3 address of `Dev.PaymentLink.PaymentLinkModuleProxy` via the EtherFiDeployer.
    address internal constant DEV_MODULE = 0x1bfCca1f03252D6734dCaB45F37AE3f81f6E0781;
    /// @dev CREATE3 address of `Prod.PaymentLink.PaymentLinkModuleProxy` via the EtherFiDeployer.
    address internal constant PROD_MODULE = 0x7402a988651bAF0558642647e0D7366D939d35c4;

    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.ModuleBaseStorage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant MODULE_BASE_SLOT = 0x9425b2e03e09da4c20ff7a465da264f7a02bf7079e1dbb47fce0436e1d206d00;
    // keccak256(abi.encode(uint256(keccak256("etherfi.storage.PaymentLinkModule")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant PAYMENT_LINK_SLOT = 0x72f6ddc7d992479425dc8c9c22860bd7f83946c3315c4ff3de0873cbf7571b00;

    struct Vector {
        string name;
        address module;
        address safe;
        address token;
        uint256 amount;
        uint256 linkSignerTestPrivateKey;
        uint16 feeBps;
        uint256 nonce;
        address recipient;
    }

    struct Computed {
        address linkSigner;
        bytes32 domainSeparator;
        bytes32 requestLinkMessageHash;
        bytes32 requestLinkDigest;
        bytes32 cancelLinkMessageHash;
        bytes32 cancelLinkDigest;
        bytes32 claimStructHash;
        bytes32 claimDigest;
        bytes claimSignature;
    }

    function _vectors() internal pure returns (Vector[3] memory v) {
        v[0] = Vector({
            name: "dev-usdc-25-fee30-nonce0",
            module: DEV_MODULE,
            safe: 0x1111111111111111111111111111111111111111,
            token: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85, // USDC (Optimism)
            amount: 25_000_000,
            linkSignerTestPrivateKey: 1,
            feeBps: 30,
            nonce: 0,
            recipient: 0x2222222222222222222222222222222222222222
        });
        v[1] = Vector({
            name: "prod-weeth-1.5-fee0-nonce7",
            module: PROD_MODULE,
            safe: 0x3333333333333333333333333333333333333333,
            token: 0x5A7fACB970D094B6C7FF1df0eA68D99E6e73CBFF, // weETH (Optimism)
            amount: 1.5 ether,
            linkSignerTestPrivateKey: 2,
            feeBps: 0,
            nonce: 7,
            recipient: 0x4444444444444444444444444444444444444444
        });
        v[2] = Vector({
            name: "prod-max-fee100-nonce123456",
            module: PROD_MODULE,
            safe: 0x5555555555555555555555555555555555555555,
            token: 0x6666666666666666666666666666666666666666,
            amount: type(uint128).max,
            linkSignerTestPrivateKey: 3,
            feeBps: 100,
            nonce: 123_456,
            recipient: 0x7777777777777777777777777777777777777777
        });
    }

    function setUp() public {
        vm.chainId(CHAIN_ID);
        address cash = makeAddr("vectorCashModule");
        VectorDataProvider dp = new VectorDataProvider(cash);
        // The module's runtime code at the deterministic proxy addresses: the views read only
        // `address(this)`, `block.chainid` and the module's own storage.
        deployCodeTo("PaymentLinkModule.sol:PaymentLinkModule", abi.encode(address(dp), cash), DEV_MODULE);
        deployCodeTo("PaymentLinkModule.sol:PaymentLinkModule", abi.encode(address(dp), cash), PROD_MODULE);
    }

    function test_digestVectors_matchFixture() public {
        Vector[3] memory v = _vectors();
        if (vm.envOr("PAYMENT_LINK_WRITE_VECTORS", false)) _writeFixture(v);

        string memory json = vm.readFile(FIXTURE);
        assertEq(json.readUint(".chainId"), CHAIN_ID);
        assertEq(json.readString(".domain.name"), "EtherFi PaymentLinkModule");
        assertEq(json.readString(".domain.version"), "1");

        for (uint256 i = 0; i < v.length; i++) {
            Computed memory c = _compute(v[i]);
            string memory p = string.concat(".vectors[", vm.toString(i), "]");

            assertEq(json.readString(string.concat(p, ".name")), v[i].name);
            assertEq(json.readAddress(string.concat(p, ".inputs.module")), v[i].module);
            assertEq(json.readAddress(string.concat(p, ".inputs.safe")), v[i].safe);
            assertEq(json.readAddress(string.concat(p, ".inputs.token")), v[i].token);
            assertEq(vm.parseUint(json.readString(string.concat(p, ".inputs.amount"))), v[i].amount);
            assertEq(json.readAddress(string.concat(p, ".inputs.linkSigner")), c.linkSigner);
            assertEq(json.readUint(string.concat(p, ".inputs.feeBps")), v[i].feeBps);
            assertEq(json.readUint(string.concat(p, ".inputs.nonce")), v[i].nonce);
            assertEq(json.readAddress(string.concat(p, ".inputs.recipient")), v[i].recipient);

            assertEq(json.readBytes32(string.concat(p, ".expected.domainSeparator")), c.domainSeparator, "domainSeparator");
            assertEq(json.readBytes32(string.concat(p, ".expected.requestLinkMessageHash")), c.requestLinkMessageHash, "requestLinkMessageHash");
            assertEq(json.readBytes32(string.concat(p, ".expected.requestLinkDigest")), c.requestLinkDigest, "requestLinkDigest");
            assertEq(json.readBytes32(string.concat(p, ".expected.cancelLinkMessageHash")), c.cancelLinkMessageHash, "cancelLinkMessageHash");
            assertEq(json.readBytes32(string.concat(p, ".expected.cancelLinkDigest")), c.cancelLinkDigest, "cancelLinkDigest");
            assertEq(json.readBytes32(string.concat(p, ".expected.claimStructHash")), c.claimStructHash, "claimStructHash");
            assertEq(json.readBytes32(string.concat(p, ".expected.claimDigest")), c.claimDigest, "claimDigest");
            assertEq(json.readBytes(string.concat(p, ".expected.claimSignature")), c.claimSignature, "claimSignature");
        }
    }

    /// @dev Reads the digests from the deployed module code and cross-checks each one against
    ///      the spec formula rebuilt here, so the fixture is never a copy of one implementation.
    function _compute(Vector memory v) internal returns (Computed memory c) {
        PaymentLinkModule module = PaymentLinkModule(v.module);
        c.linkSigner = vm.addr(v.linkSignerTestPrivateKey);

        // nonces[safe] in ModuleBase storage; links[linkSigner].safe in module storage.
        vm.store(v.module, keccak256(abi.encode(v.safe, MODULE_BASE_SLOT)), bytes32(v.nonce));
        vm.store(v.module, keccak256(abi.encode(c.linkSigner, PAYMENT_LINK_SLOT)), bytes32(uint256(uint160(v.safe))));
        assertEq(module.getNonce(v.safe), v.nonce);
        assertEq(module.getLink(c.linkSigner).safe, v.safe);

        c.domainSeparator = keccak256(abi.encode(keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"), keccak256("EtherFi PaymentLinkModule"), keccak256("1"), CHAIN_ID, v.module));
        assertEq(module.DOMAIN_SEPARATOR(), c.domainSeparator);

        c.requestLinkMessageHash = keccak256(abi.encodePacked(keccak256("requestLink"), CHAIN_ID, v.module, v.nonce, v.safe, abi.encode(v.token, v.amount, c.linkSigner, v.feeBps)));
        c.requestLinkDigest = c.requestLinkMessageHash.toEthSignedMessageHash();
        assertEq(module.requestLinkDigest(v.safe, v.token, v.amount, c.linkSigner, v.feeBps), c.requestLinkDigest);

        c.cancelLinkMessageHash = keccak256(abi.encodePacked(keccak256("cancelLink"), CHAIN_ID, v.module, v.nonce, v.safe, c.linkSigner));
        c.cancelLinkDigest = c.cancelLinkMessageHash.toEthSignedMessageHash();
        assertEq(module.cancelLinkDigest(c.linkSigner), c.cancelLinkDigest);

        c.claimStructHash = keccak256(abi.encode(keccak256("Claim(address linkSigner,address recipient)"), c.linkSigner, v.recipient));
        c.claimDigest = keccak256(abi.encodePacked("\x19\x01", c.domainSeparator, c.claimStructHash));
        assertEq(module.claimDigest(c.linkSigner, v.recipient), c.claimDigest);

        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(v.linkSignerTestPrivateKey, c.claimDigest);
        c.claimSignature = abi.encodePacked(r, s, sv);
        assertEq(ECDSA.recover(c.claimDigest, c.claimSignature), c.linkSigner);
    }

    function _writeFixture(Vector[3] memory v) internal {
        string memory out = string.concat(
            "{\n",
            '  "description": "PaymentLinkModule digest test vectors (payment-links build spec v1.2, section 2). Private keys here are TEST-ONLY values 1, 2 and 3. requestLinkDigest and cancelLinkDigest are the EIP-191 hashes checkSignatures verifies, i.e. personal_sign over the 32-byte *MessageHash. claimDigest is the EIP-712 hash the link key signs with a raw (no prefix) ECDSA signature, encoded r || s || v.",\n',
            '  "chainId": ',
            vm.toString(CHAIN_ID),
            ",\n",
            '  "domain": { "name": "EtherFi PaymentLinkModule", "version": "1" },\n',
            '  "constants": {\n',
            '    "REQUEST_LINK_SIG": "',
            vm.toString(keccak256("requestLink")),
            '",\n',
            '    "CANCEL_LINK_SIG": "',
            vm.toString(keccak256("cancelLink")),
            '",\n',
            '    "CLAIM_TYPEHASH": "',
            vm.toString(keccak256("Claim(address linkSigner,address recipient)")),
            '"\n',
            "  },\n",
            '  "vectors": [\n'
        );
        for (uint256 i = 0; i < v.length; i++) {
            out = string.concat(out, _vectorJson(v[i], _compute(v[i])), i + 1 < v.length ? ",\n" : "\n");
        }
        out = string.concat(out, "  ]\n}\n");
        vm.writeFile(FIXTURE, out);
    }

    function _vectorJson(Vector memory v, Computed memory c) internal pure returns (string memory) {
        string memory inputs = string.concat(
            '      "inputs": {\n',
            '        "module": "', vm.toString(v.module), '",\n',
            '        "safe": "', vm.toString(v.safe), '",\n',
            '        "token": "', vm.toString(v.token), '",\n',
            '        "amount": "', vm.toString(v.amount), '",\n',
            '        "linkSigner": "', vm.toString(c.linkSigner), '",\n',
            '        "linkSignerTestPrivateKey": "', vm.toString(bytes32(v.linkSignerTestPrivateKey)), '",\n',
            '        "feeBps": ', vm.toString(v.feeBps), ",\n",
            '        "nonce": ', vm.toString(v.nonce), ",\n",
            '        "recipient": "', vm.toString(v.recipient), '"\n',
            "      },\n"
        );
        string memory expected = string.concat(
            '      "expected": {\n',
            '        "domainSeparator": "', vm.toString(c.domainSeparator), '",\n',
            '        "requestLinkMessageHash": "', vm.toString(c.requestLinkMessageHash), '",\n',
            '        "requestLinkDigest": "', vm.toString(c.requestLinkDigest), '",\n',
            '        "cancelLinkMessageHash": "', vm.toString(c.cancelLinkMessageHash), '",\n',
            '        "cancelLinkDigest": "', vm.toString(c.cancelLinkDigest), '",\n',
            '        "claimStructHash": "', vm.toString(c.claimStructHash), '",\n',
            '        "claimDigest": "', vm.toString(c.claimDigest), '",\n',
            '        "claimSignature": "', vm.toString(c.claimSignature), '"\n',
            "      }\n"
        );
        return string.concat("    {\n", '      "name": "', v.name, '",\n', inputs, expected, "    }");
    }
}
