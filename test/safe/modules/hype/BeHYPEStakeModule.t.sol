// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SafeTestSetup } from "../../SafeTestSetup.t.sol";
import { BeHYPEStakeModule } from "../../../../src/modules/hype/BeHYPEStakeModule.sol";
import { MockERC20 } from "../../../../src/mocks/MockERC20.sol";
import { IL2BeHYPEOAppStaker } from "../../../../src/interfaces/IL2BeHYPEOAppStaker.sol";

contract MockL2BeHYPEOAppStaker is IL2BeHYPEOAppStaker {
    uint256 public quote;
    uint256 public lastStakeAmount;
    address public lastStakeReceiver;
    uint256 public lastStakeValue;

    function setQuote(uint256 newQuote) external {
        quote = newQuote;
    }

    function quoteStake(uint256, address) external view override returns (uint256) {
        return quote;
    }

    function stake(uint256 hypeAmountIn, address receiver) external payable override {
        lastStakeAmount = hypeAmountIn;
        lastStakeReceiver = receiver;
        lastStakeValue = msg.value;
    }
}

contract BeHYPEStakeModuleTest is SafeTestSetup {
    BeHYPEStakeModule public stakeModule;
    MockL2BeHYPEOAppStaker public staker;
    MockERC20 public whype;
    MockERC20 public beHYPE;

    uint256 internal constant QUOTE_FEE = 0.01 ether;
    uint32 internal constant DEFAULT_REFUND_GAS_LIMIT = 5_000;
    bytes32 internal constant STORAGE_SLOT = 0x7360fa4520b143a14b5f377b55b454493ca513d405fba1b8dcff3eff4e862c00;

    function setUp() public override {
        super.setUp();

        staker = new MockL2BeHYPEOAppStaker();
        staker.setQuote(QUOTE_FEE);

        whype = new MockERC20("WHYPE", "WHYPE", 18);
        beHYPE = new MockERC20("beHYPE", "beHYPE", 18);

        stakeModule = new BeHYPEStakeModule(address(dataProvider), address(staker), address(whype), address(beHYPE), DEFAULT_REFUND_GAS_LIMIT);

        address[] memory modules = new address[](1);
        modules[0] = address(stakeModule);

        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;

        bytes[] memory setupData = new bytes[](1);
        setupData[0] = "";

        vm.startPrank(owner);
        dataProvider.configureModules(modules, shouldWhitelist);
        roleRegistry.grantRole(stakeModule.BEHYPE_STAKE_MODULE_ADMIN_ROLE(), address(this));
        vm.stopPrank();

        _configureModules(modules, shouldWhitelist, setupData);
    }

    function _toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function _deriveSlotFromSpec() internal pure returns (bytes32) {
        bytes32 namespaceHash = keccak256(abi.encodePacked("etherfi.storage.BeHYPEStakeModule"));
        uint256 storageLocation = uint256(namespaceHash) - 1;
        bytes32 hashedLocation = keccak256(abi.encode(storageLocation));
        return hashedLocation & ~bytes32(uint256(0xff));
    }

    function test_storageSlot_hashMatchesSpec() public pure {
        bytes32 derivedSlot = _deriveSlotFromSpec();
        assertEq(derivedSlot, STORAGE_SLOT, "storage slot derivation mismatch");
    }

    function test_stake_executesHappyPath() public {
        uint256 amountToStake = 250 ether;
        uint256 nonceBefore = stakeModule.getNonce(address(safe));

        whype.mint(address(safe), amountToStake);
        vm.deal(address(this), QUOTE_FEE + 0.005 ether);

        bytes32 digestHash = keccak256(
            abi.encodePacked(
                stakeModule.STAKE_SIG(),
                block.chainid,
                address(stakeModule),
                nonceBefore,
                address(safe),
                abi.encode(amountToStake)
            )
        );
        digestHash = _toEthSignedMessageHash(digestHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectEmit(true, true, true, true, address(stakeModule));
        emit BeHYPEStakeModule.StakeDeposit(address(safe), address(whype), address(beHYPE), amountToStake);
        stakeModule.stake{ value: QUOTE_FEE + 0.005 ether }(address(safe), amountToStake, owner1, signature);
    }

    function test_setRefundGasLimit_reconfiguresValue() public {
        assertEq(stakeModule.getRefundGasLimit(), DEFAULT_REFUND_GAS_LIMIT);

        uint32 customLimit = 80_000;
        stakeModule.setRefundGasLimit(customLimit);
        assertEq(stakeModule.getRefundGasLimit(), customLimit);

        stakeModule.setRefundGasLimit(0);
        assertEq(stakeModule.getRefundGasLimit(), 0);
    }

    receive() external payable { }
}

