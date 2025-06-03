// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { SafeTestSetup, MessageHashUtils } from "../../SafeTestSetup.t.sol";
import { EtherFiLiquidModule } from "../../../../src/modules/etherfi/EtherFiLiquidModule.sol";
import { ModuleBase } from "../../../../src/modules/ModuleBase.sol";
import { IBoringOnChainQueue } from "../../../../src/interfaces/IBoringOnChainQueue.sol";
import { IDebtManager } from "../../../../src/interfaces/IDebtManager.sol";
import { ILayerZeroTeller } from "../../../../src/interfaces/ILayerZeroTeller.sol";
import { IEtherFiSafe } from "../../../../src/interfaces/IEtherFiSafe.sol";
import { IEtherFiDataProvider } from "../../../../src/interfaces/IEtherFiDataProvider.sol";

contract EtherFiLiquidModuleTest is SafeTestSetup {
    using MessageHashUtils for bytes32;

    EtherFiLiquidModule public liquidModule;

    uint32 mainnetEid = 30101;
    
    IERC20 public weth = IERC20(0x5300000000000000000000000000000000000004);
    IERC20 public weEth = IERC20(0x01f0a31698C4d065659b9bdC21B3610292a1c506);
    IERC20 public usdc = IERC20(0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4);
    IERC20 public usdt = IERC20(0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df);
    IERC20 public dai = IERC20(0xcA77eB3fEFe3725Dc33bccB54eDEFc3D9f764f97);
    IERC20 public wbtc = IERC20(0x3C1BCa5a656e69edCD0D4E36BEbb3FcDAcA60Cf1);
    IERC20 public usde = IERC20(0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34);
    
    IERC20 public liquidEth = IERC20(0xf0bb20865277aBd641a307eCe5Ee04E79073416C);
    address public liquidEthTeller = 0x9AA79C84b79816ab920bBcE20f8f74557B514734;
    
    IERC20 public liquidUsd = IERC20(0x08c6F91e2B681FaF5e17227F2a44C307b3C1364C);
    address public liquidUsdTeller = 0x4DE413a26fC24c3FC27Cc983be70aA9c5C299387;
    
    IERC20 public liquidBtc = IERC20(0x5f46d540b6eD704C3c8789105F30E075AA900726);
    address public liquidBtcTeller = 0x8Ea0B382D054dbEBeB1d0aE47ee4AC433C730353 ;

    IERC20 public eUsd = IERC20(0x939778D83b46B456224A33Fb59630B11DEC56663);
    address public eUsdTeller = 0xCc9A7620D0358a521A068B444846E3D5DebEa8fA;

    IERC20 public ebtc = IERC20(0x657e8C867D8B37dCC18fA4Caead9C45EB088C642);
    address public ebtcTeller = address(0x6Ee3aaCcf9f2321E49063C4F8da775DdBd407268);

    IBoringOnChainQueue public liquidUsdBoringQueue = IBoringOnChainQueue(0x38FC1BA73b7ED289955a07d9F11A85b6E388064A);
    IBoringOnChainQueue public liquidEthBoringQueue = IBoringOnChainQueue(0x0D2dF071207E18Ca8638b4f04E98c53155eC2cE0);
    IBoringOnChainQueue public liquidBtcBoringQueue = IBoringOnChainQueue(0x77A2fd42F8769d8063F2E75061FC200014E41Edf);

    address liquidUsdAssetOut = address(usdc);
    address liquidEthAssetOut = address(weEth);
    address liquidBtcAssetOut = address(wbtc);

    uint16 discount = 1; 
    uint24 secondsToDeadline = 3 days;

    address public ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    
    function setUp() public override {
        super.setUp();
        
        vm.startPrank(owner);
        
        address[] memory assets = new address[](5);
        assets[0] = address(liquidEth);
        assets[1] = address(liquidBtc);
        assets[2] = address(liquidUsd);
        assets[3] = address(eUsd);
        assets[4] = address(ebtc);
        
        address[] memory tellers = new address[](5);
        tellers[0] = liquidEthTeller;
        tellers[1] = liquidBtcTeller;
        tellers[2] = liquidUsdTeller;
        tellers[3] = eUsdTeller;
        tellers[4] = ebtcTeller;
        
        liquidModule = new EtherFiLiquidModule(assets, tellers, address(dataProvider), address(weth));
        
        address[] memory modules = new address[](1);
        modules[0] = address(liquidModule);
        
        bool[] memory shouldWhitelist = new bool[](1);
        shouldWhitelist[0] = true;
        
        bytes[] memory moduleSetupData = new bytes[](1);
        moduleSetupData[0] = "";
        
        dataProvider.configureModules(modules, shouldWhitelist);
        _configureModules(modules, shouldWhitelist, moduleSetupData);

        roleRegistry.grantRole(liquidModule.ETHERFI_LIQUID_MODULE_ADMIN(), owner);

        liquidModule.setLiquidAssetWithdrawQueue(address(liquidUsd), address(liquidUsdBoringQueue));
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidEth), address(liquidEthBoringQueue));
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidBtc), address(liquidBtcBoringQueue));
        
        vm.stopPrank();
    }

    function test_bridge_worksforLiquidEth() public {
        uint256 amountToBridge = 1 ether;
        deal(address(liquidEth), address(safe), amountToBridge);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.BRIDGE_SIG(),
            block.chainid,
            address(liquidModule),
            safe.nonce(),
            address(safe),
            abi.encode(address(liquidEth), mainnetEid, owner, amountToBridge)
        )).toEthSignedMessageHash();

        uint256 fee = liquidModule.getBridgeFee(address(liquidEth), mainnetEid, owner, amountToBridge);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature1 = abi.encodePacked(r, s, v); 
        
        (v, r, s) = vm.sign(owner2Pk, digestHash);
        bytes memory signature2 = abi.encodePacked(r, s, v); 

        uint256 liquidAssetBalBefore = liquidEth.balanceOf(address(safe));
        _bridgeLiquid(address(liquidEth), mainnetEid, amountToBridge, signature1, signature2, fee);
        uint256 liquidAssetBalAfter = liquidEth.balanceOf(address(safe));
        assertEq(liquidAssetBalAfter, liquidAssetBalBefore - amountToBridge);
    }

    function test_bridge_worksforEBtc() public {
        uint256 amountToBridge = 1e6;
        deal(address(ebtc), address(safe), amountToBridge);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.BRIDGE_SIG(),
            block.chainid,
            address(liquidModule),
            safe.nonce(),
            address(safe),
            abi.encode(address(ebtc), mainnetEid, owner, amountToBridge)
        )).toEthSignedMessageHash();

        uint256 fee = liquidModule.getBridgeFee(address(ebtc), mainnetEid, owner, amountToBridge);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature1 = abi.encodePacked(r, s, v); 
        
        (v, r, s) = vm.sign(owner2Pk, digestHash);
        bytes memory signature2 = abi.encodePacked(r, s, v); 

        uint256 liquidAssetBalBefore = ebtc.balanceOf(address(safe));
        _bridgeLiquid(address(ebtc), mainnetEid, amountToBridge, signature1, signature2, fee);
        uint256 liquidAssetBalAfter = ebtc.balanceOf(address(safe));
        assertEq(liquidAssetBalAfter, liquidAssetBalBefore - amountToBridge);
    }

    function test_bridge_worksforLiquidBtc() public {
        uint256 amountToBridge = 1e5;
        deal(address(liquidBtc), address(safe), amountToBridge);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.BRIDGE_SIG(),
            block.chainid,
            address(liquidModule),
            safe.nonce(),
            address(safe),
            abi.encode(address(liquidBtc), mainnetEid, owner, amountToBridge)
        )).toEthSignedMessageHash();

        uint256 fee = liquidModule.getBridgeFee(address(liquidBtc), mainnetEid, owner, amountToBridge);

        uint256 liquidAssetBalBefore = liquidBtc.balanceOf(address(safe));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature1 = abi.encodePacked(r, s, v); 
        
        (v, r, s) = vm.sign(owner2Pk, digestHash);
        bytes memory signature2 = abi.encodePacked(r, s, v); 

        _bridgeLiquid(address(liquidBtc), mainnetEid, amountToBridge, signature1, signature2, fee);

        uint256 liquidAssetBalAfter = liquidBtc.balanceOf(address(safe));

        assertEq(liquidAssetBalAfter, liquidAssetBalBefore - amountToBridge);
    }

    function test_bridge_worksforLiquidUsd() public {
        uint256 amountToBridge = 1e6;
        deal(address(liquidUsd), address(safe), amountToBridge);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.BRIDGE_SIG(),
            block.chainid,
            address(liquidModule),
            safe.nonce(),
            address(safe),
            abi.encode(address(liquidUsd), mainnetEid, owner, amountToBridge)
        )).toEthSignedMessageHash();

        uint256 fee = liquidModule.getBridgeFee(address(liquidUsd), mainnetEid, owner, amountToBridge);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature1 = abi.encodePacked(r, s, v); 
        
        (v, r, s) = vm.sign(owner2Pk, digestHash);
        bytes memory signature2 = abi.encodePacked(r, s, v); 

        uint256 liquidAssetBalBefore = liquidUsd.balanceOf(address(safe));
        _bridgeLiquid(address(liquidUsd), mainnetEid, amountToBridge, signature1, signature2, fee);
        uint256 liquidAssetBalAfter = liquidUsd.balanceOf(address(safe));
        assertEq(liquidAssetBalAfter, liquidAssetBalBefore - amountToBridge);
    }

    function test_bridge_worksforEUsd() public {
        uint256 amountToBridge = 1e6;
        deal(address(eUsd), address(safe), amountToBridge);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.BRIDGE_SIG(),
            block.chainid,
            address(liquidModule),
            safe.nonce(),
            address(safe),
            abi.encode(address(eUsd), mainnetEid, owner, amountToBridge)
        )).toEthSignedMessageHash();

        uint256 fee = liquidModule.getBridgeFee(address(eUsd), mainnetEid, owner, amountToBridge);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature1 = abi.encodePacked(r, s, v); 
        
        (v, r, s) = vm.sign(owner2Pk, digestHash);
        bytes memory signature2 = abi.encodePacked(r, s, v); 

        uint256 liquidAssetBalBefore = eUsd.balanceOf(address(safe));
        _bridgeLiquid(address(eUsd), mainnetEid, amountToBridge, signature1, signature2, fee);
        uint256 liquidAssetBalAfter = eUsd.balanceOf(address(safe));
        assertEq(liquidAssetBalAfter, liquidAssetBalBefore - amountToBridge);
    }

    function _bridgeLiquid(address liquidAsset, uint32 destEid, uint256 amountToBridge, bytes memory signature1, bytes memory signature2, uint256 fee) internal {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = signature1;
        signatures[1] = signature2;

        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModule.LiquidBridged(address(safe), address(liquidAsset), owner, destEid, amountToBridge, fee);
        liquidModule.bridge{value: fee}(address(safe), address(liquidAsset), destEid, owner, amountToBridge, owners, signatures);
    }

    function test_deposit_worksWithWeth_forLiquidEth() public {
        uint256 amountToDeposit = 1 ether;
        uint256 minReturn = 0.5 ether; 
        deal(address(weth), address(safe), amountToDeposit);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(weth), address(liquidEth), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 

        uint256 wethBalBefore = weth.balanceOf(address(safe));
        uint256 liquidEthBalBefore = liquidEth.balanceOf(address(safe));

        liquidModule.deposit(address(safe), address(weth), address(liquidEth), amountToDeposit, minReturn, owner1, signature);
        
        uint256 wethBalAfter = weth.balanceOf(address(safe));
        uint256 liquidEthBalAfter = liquidEth.balanceOf(address(safe));

        assertEq(wethBalAfter, wethBalBefore - amountToDeposit);
        assertGt(liquidEthBalAfter, liquidEthBalBefore);
    }

    function test_deposit_worksWithEth_forLiquidEth() public {
        uint256 amountToDeposit = 1 ether;
        uint256 minReturn = 0.5 ether; 
        deal(address(safe), amountToDeposit);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(ETH, address(liquidEth), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 

        uint256 ethBalBefore = address(safe).balance;
        uint256 liquidEthBalBefore = liquidEth.balanceOf(address(safe));

        liquidModule.deposit(address(safe), ETH, address(liquidEth), amountToDeposit, minReturn, owner1, signature);
        
        uint256 ethBalAfter = address(safe).balance;
        uint256 liquidEthBalAfter = liquidEth.balanceOf(address(safe));

        assertEq(ethBalAfter, ethBalBefore - amountToDeposit);
        assertGt(liquidEthBalAfter, liquidEthBalBefore);
    }

    function test_deposit_worksWithWeEth_forLiquidEth() public {
        uint256 amountToDeposit = 1 ether;
        uint256 minReturn = 0.5 ether; 
        deal(address(weEth), address(safe), amountToDeposit);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(weEth), address(liquidEth), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 

        uint256 weEthBalBefore = weEth.balanceOf(address(safe));
        uint256 liquidEthBalBefore = liquidEth.balanceOf(address(safe));

        liquidModule.deposit(address(safe), address(weEth), address(liquidEth), amountToDeposit, minReturn, owner1, signature);
        
        uint256 weEthBalAfter = weEth.balanceOf(address(safe));
        uint256 liquidEthBalAfter = liquidEth.balanceOf(address(safe));

        assertEq(weEthBalAfter, weEthBalBefore - amountToDeposit);
        assertGt(liquidEthBalAfter, liquidEthBalBefore);
    }

    // Tests for LiquidUSD with USDC, USDT, DAI
    function test_deposit_worksWithUsdc_forLiquidUsd() public {
        uint256 amountToDeposit = 1000 * 10**6; // 1000 USDC (6 decimals)
        uint256 minReturn = 900 * 10**6; // 990 LiquidUSD (18 decimals)
        deal(address(usdc), address(safe), amountToDeposit);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(usdc), address(liquidUsd), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 
        
        uint256 usdcBalBefore = usdc.balanceOf(address(safe));
        uint256 liquidUsdBalBefore = liquidUsd.balanceOf(address(safe));
        
        liquidModule.deposit(address(safe), address(usdc), address(liquidUsd), amountToDeposit, minReturn, owner1, signature);
        
        uint256 usdcBalAfter = usdc.balanceOf(address(safe));
        uint256 liquidUsdBalAfter = liquidUsd.balanceOf(address(safe));
        
        assertEq(usdcBalAfter, usdcBalBefore - amountToDeposit);
        assertGt(liquidUsdBalAfter, liquidUsdBalBefore);
    }

    function test_deposit_worksWithUsdt_forLiquidUsd() public {
        uint256 amountToDeposit = 1000 * 10**6; // 1000 USDT (6 decimals)
        uint256 minReturn = 900 * 10**6; // 990 LiquidUSD (18 decimals)
        deal(address(usdt), address(safe), amountToDeposit);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(usdt), address(liquidUsd), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 
        
        uint256 usdtBalBefore = usdt.balanceOf(address(safe));
        uint256 liquidUsdBalBefore = liquidUsd.balanceOf(address(safe));
        
        liquidModule.deposit(address(safe), address(usdt), address(liquidUsd), amountToDeposit, minReturn, owner1, signature);
        
        uint256 usdtBalAfter = usdt.balanceOf(address(safe));
        uint256 liquidUsdBalAfter = liquidUsd.balanceOf(address(safe));
        
        assertEq(usdtBalAfter, usdtBalBefore - amountToDeposit);
        assertGt(liquidUsdBalAfter, liquidUsdBalBefore);
    }

    function test_deposit_worksWithDai_forLiquidUsd() public {
        uint256 amountToDeposit = 1000 * 10**18; // 1000 DAI (18 decimals)
        uint256 minReturn = 900 * 10**6; // 990 LiquidUSD (18 decimals)
        deal(address(dai), address(safe), amountToDeposit);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(dai), address(liquidUsd), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 
        
        uint256 daiBalBefore = dai.balanceOf(address(safe));
        uint256 liquidUsdBalBefore = liquidUsd.balanceOf(address(safe));
        
        liquidModule.deposit(address(safe), address(dai), address(liquidUsd), amountToDeposit, minReturn, owner1, signature);
        
        uint256 daiBalAfter = dai.balanceOf(address(safe));
        uint256 liquidUsdBalAfter = liquidUsd.balanceOf(address(safe));
        
        assertEq(daiBalAfter, daiBalBefore - amountToDeposit);
        assertGt(liquidUsdBalAfter, liquidUsdBalBefore);
    }

    // Test for LiquidBTC with WBTC
    function test_deposit_worksWithWbtc_forLiquidBtc() public {
        uint256 amountToDeposit = 1 * 10**8; // 1 WBTC (8 decimals)
        uint256 minReturn = 0.95 * 10**8; // 0.95 LiquidBTC (18 decimals)
        deal(address(wbtc), address(safe), amountToDeposit);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(wbtc), address(liquidBtc), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 
        
        uint256 wbtcBalBefore = wbtc.balanceOf(address(safe));
        uint256 liquidBtcBalBefore = liquidBtc.balanceOf(address(safe));
        
        liquidModule.deposit(address(safe), address(wbtc), address(liquidBtc), amountToDeposit, minReturn, owner1, signature);
        
        uint256 wbtcBalAfter = wbtc.balanceOf(address(safe));
        uint256 liquidBtcBalAfter = liquidBtc.balanceOf(address(safe));
        
        assertEq(wbtcBalAfter, wbtcBalBefore - amountToDeposit);
        assertGt(liquidBtcBalAfter, liquidBtcBalBefore);
    }

    // Test for eBTC with WBTC
    function test_deposit_worksWithEbtc_forLiquidBtc() public {
        uint256 amountToDeposit = 1 * 10**8; // 1 WBTC (8 decimals)
        uint256 minReturn = 0.95 * 10**8; // 0.95 LiquidBTC (18 decimals)
        deal(address(wbtc), address(safe), amountToDeposit);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(wbtc), address(ebtc), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 
        
        uint256 wbtcBalBefore = wbtc.balanceOf(address(safe));
        uint256 eBtcBalBefore = ebtc.balanceOf(address(safe));
        
        liquidModule.deposit(address(safe), address(wbtc), address(ebtc), amountToDeposit, minReturn, owner1, signature);
        
        uint256 wbtcBalAfter = wbtc.balanceOf(address(safe));
        uint256 eBtcBalAfter = ebtc.balanceOf(address(safe));
        
        assertEq(wbtcBalAfter, wbtcBalBefore - amountToDeposit);
        assertGt(eBtcBalAfter, eBtcBalBefore);
    }

    // Test for eUSD with USDe
    function test_deposit_worksWithUsde_forEUsd() public {
        uint256 amountToDeposit = 1000 * 10**18; // 1000 USDe (18 decimals)
        uint256 minReturn = 900 * 10**18; // 990 eUSD (18 decimals)
        deal(address(usde), address(safe), amountToDeposit);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(usde), address(eUsd), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v); 
        
        uint256 usdeBalBefore = usde.balanceOf(address(safe));
        uint256 eUsdBalBefore = eUsd.balanceOf(address(safe));
        
        liquidModule.deposit(address(safe), address(usde), address(eUsd), amountToDeposit, minReturn, owner1, signature);
        
        uint256 usdeBalAfter = usde.balanceOf(address(safe));
        uint256 eUsdBalAfter = eUsd.balanceOf(address(safe));
        
        assertEq(usdeBalAfter, usdeBalBefore - amountToDeposit);
        assertGt(eUsdBalAfter, eUsdBalBefore);
    }

    // Failure tests for each vault type

    // Test failure for LiquidUSD: unsupported asset
    function test_deposit_revertsWithUnsupportedAsset_forLiquidUsd() public {
        uint256 amountToDeposit = 1 * 10**18; // 1 random token
        uint256 minReturn = 0.95 * 10**18;
        
        // Use a random address as unsupported token
        address randomToken = address(0x1111111111111111111111111111111111111111);
        
        // Mock balance check
        vm.mockCall(
            randomToken,
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(safe)),
            abi.encode(amountToDeposit)
        );
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(randomToken, address(liquidUsd), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // Mock the teller response for asset data
        vm.mockCall(
            liquidUsdTeller,
            abi.encodeWithSelector(ILayerZeroTeller.assetData.selector, ERC20(randomToken)),
            abi.encode(false, 0, 0) // allowDeposits = false
        );
        
        vm.expectRevert(EtherFiLiquidModule.AssetNotSupportedForDeposit.selector);
        liquidModule.deposit(address(safe), randomToken, address(liquidUsd), amountToDeposit, minReturn, owner1, signature);
    }

    // Test failure for LiquidBTC: insufficient balance
    function test_deposit_revertsWithInsufficientBalance_forLiquidBtc() public {
        uint256 amountToDeposit = 2 * 10**8; // 2 WBTC
        uint256 minReturn = 1.9 * 10**18;
        
        // Give the safe only 1 WBTC, but try to deposit 2 WBTC
        uint256 actualBalance = 1 * 10**8;
        deal(address(wbtc), address(safe), actualBalance);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(wbtc), address(liquidBtc), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(EtherFiLiquidModule.InsufficientBalanceOnSafe.selector);
        liquidModule.deposit(address(safe), address(wbtc), address(liquidBtc), amountToDeposit, minReturn, owner1, signature);
    }

    // Test failure for eUSD: unsupported liquid asset
    function test_deposit_revertsWithUnsupportedLiquidAsset() public {
        uint256 amountToDeposit = 1000 * 10**18; // 1000 USDe
        uint256 minReturn = 990 * 10**18;
        deal(address(usde), address(safe), amountToDeposit);
        
        // Use a non-existent liquid asset
        address fakeLiquidAsset = address(0x9999999999999999999999999999999999999999);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(usde), fakeLiquidAsset, amountToDeposit, minReturn)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(EtherFiLiquidModule.UnsupportedLiquidAsset.selector);
        liquidModule.deposit(address(safe), address(usde), fakeLiquidAsset, amountToDeposit, minReturn, owner1, signature);
    }

    // Tests for admin functions: addLiquidAssets and removeLiquidAsset

    // Test successful addition of new liquid assets
    function test_addLiquidAssets_works() public {
        // Set up new liquid asset and teller to add
        address newLiquidAsset = address(1);
        address newTeller = address(2);
        
        // Mock the teller's vault function to return the new liquid asset address
        vm.mockCall(
            newTeller,
            abi.encodeWithSelector(ILayerZeroTeller.vault.selector),
            abi.encode(newLiquidAsset)
        );

        // Create the arrays for the function call
        address[] memory assets = new address[](1);
        assets[0] = newLiquidAsset;
        
        address[] memory tellers = new address[](1);
        tellers[0] = newTeller;
        
        // Check that the new liquid asset doesn't have a teller mapped yet
        address tellerBefore = address(liquidModule.liquidAssetToTeller(newLiquidAsset));
        assertEq(tellerBefore, address(0));
        
        // Expect the LiquidAssetsAdded event to be emitted
        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModule.LiquidAssetsAdded(assets, tellers);
        
        // Call the function as owner
        vm.prank(owner);
        liquidModule.addLiquidAssets(assets, tellers);
        
        // Verify the liquid asset was mapped to the teller
        address tellerAfter = address(liquidModule.liquidAssetToTeller(newLiquidAsset));
        assertEq(tellerAfter, newTeller);
    }

    // Test adding multiple liquid assets at once
    function test_addLiquidAssets_worksWithMultipleAssets() public {
        // Set up new liquid assets and tellers to add
        address newLiquidAsset1 = address(0x1111111111111111111111111111111111111111);
        address newTeller1 = address(0x1111111111111111111111111111111111111112);
        
        address newLiquidAsset2 = address(0x2222222222222222222222222222222222222222);
        address newTeller2 = address(0x2222222222222222222222222222222222222223);
        
        // Mock the tellers' vault functions
        vm.mockCall(
            newTeller1,
            abi.encodeWithSelector(ILayerZeroTeller.vault.selector),
            abi.encode(newLiquidAsset1)
        );
        
        vm.mockCall(
            newTeller2,
            abi.encodeWithSelector(ILayerZeroTeller.vault.selector),
            abi.encode(newLiquidAsset2)
        );
        
        // Create the arrays for the function call
        address[] memory assets = new address[](2);
        assets[0] = newLiquidAsset1;
        assets[1] = newLiquidAsset2;
        
        address[] memory tellers = new address[](2);
        tellers[0] = newTeller1;
        tellers[1] = newTeller2;
        
        // Check that the new liquid assets don't have tellers mapped yet
        address teller1Before = address(liquidModule.liquidAssetToTeller(newLiquidAsset1));
        address teller2Before = address(liquidModule.liquidAssetToTeller(newLiquidAsset2));
        assertEq(teller1Before, address(0));
        assertEq(teller2Before, address(0));
        
        // Expect the LiquidAssetsAdded event to be emitted
        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModule.LiquidAssetsAdded(assets, tellers);
        
        // Call the function as owner
        vm.prank(owner);
        liquidModule.addLiquidAssets(assets, tellers);
        
        // Verify the liquid assets were mapped to their tellers
        address teller1After = address(liquidModule.liquidAssetToTeller(newLiquidAsset1));
        address teller2After = address(liquidModule.liquidAssetToTeller(newLiquidAsset2));
        assertEq(teller1After, newTeller1);
        assertEq(teller2After, newTeller2);
    }

    // Test failure when caller is not an admin
    function test_addLiquidAssets_revertsWhenNotAdmin() public {
        // Set up new liquid asset and teller to add
        address newLiquidAsset = address(1);
        address newTeller = address(2);
        
        // Mock the teller's vault function to return the new liquid asset address
        vm.mockCall(
            newTeller,
            abi.encodeWithSelector(ILayerZeroTeller.vault.selector),
            abi.encode(newLiquidAsset)
        );
        
        // Create the arrays for the function call
        address[] memory assets = new address[](1);
        assets[0] = newLiquidAsset;
        
        address[] memory tellers = new address[](1);
        tellers[0] = newTeller;
        
        // Expect the call to revert with Unauthorized
        vm.prank(address(0x123));
        vm.expectRevert(EtherFiLiquidModule.Unauthorized.selector);
        liquidModule.addLiquidAssets(assets, tellers);
    }

    // Test failure when array lengths don't match
    function test_addLiquidAssets_revertsWhenArrayLengthsMismatch() public {
        // Set up new liquid asset and teller to add
        address newLiquidAsset = address(1);
        address newTeller = address(2);
        
        // Create arrays with different lengths
        address[] memory assets = new address[](1);
        assets[0] = newLiquidAsset;
        
        address[] memory tellers = new address[](2);
        tellers[0] = newTeller;
        tellers[1] = address(0x789);
        
        // Expect the call to revert with ArrayLengthMismatch
        vm.prank(owner);
        vm.expectRevert(ModuleBase.ArrayLengthMismatch.selector);
        liquidModule.addLiquidAssets(assets, tellers);
    }

    // Test failure when teller's vault doesn't match the liquid asset
    function test_addLiquidAssets_revertsWhenInvalidConfiguration() public {
        // Set up new liquid asset and teller to add
        address newLiquidAsset = address(1);
        address newTeller = address(2);
        
        // Mock the teller's vault function to return a DIFFERENT address than the liquid asset
        address differentAddress = address(0x9999999999999999999999999999999999999999);
        vm.mockCall(
            newTeller,
            abi.encodeWithSelector(ILayerZeroTeller.vault.selector),
            abi.encode(differentAddress)
        );

        // Create the arrays for the function call
        address[] memory assets = new address[](1);
        assets[0] = newLiquidAsset;
        
        address[] memory tellers = new address[](1);
        tellers[0] = newTeller;
        
        // Expect the call to revert with InvalidConfiguration
        vm.prank(owner);
        vm.expectRevert(EtherFiLiquidModule.InvalidConfiguration.selector);
        liquidModule.addLiquidAssets(assets, tellers);
    }

    // Test failure when passing empty arrays
    function test_addLiquidAssets_revertsWhenEmptyArrays() public {
        // Create empty arrays
        address[] memory assets = new address[](0);
        address[] memory tellers = new address[](0);
        
        // Expect the call to revert with InvalidInput
        vm.prank(owner);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        liquidModule.addLiquidAssets(assets, tellers);
    }

    // Test failure when passing zero addresses
    function test_addLiquidAssets_revertsWhenZeroAddress() public {
        // Create arrays with zero address
        address[] memory assets = new address[](1);
        assets[0] = address(0);
        
        address[] memory tellers = new address[](1);
        tellers[0] = address(0x123); // Valid address
        
        // Expect the call to revert with InvalidInput
        vm.prank(owner);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        liquidModule.addLiquidAssets(assets, tellers);
        
        // Try with valid asset but zero teller
        assets[0] = address(0x456); // Valid address
        tellers[0] = address(0); // Zero address
        
        // Expect the call to revert with InvalidInput
        vm.prank(owner);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        liquidModule.addLiquidAssets(assets, tellers);
    }

    // Tests for removeLiquidAsset

    // Test successful removal of a liquid asset
    function test_removeLiquidAsset_works() public {
        // Use an existing liquid asset from the setup
        address existingLiquidAsset = address(liquidEth);
        
        // Verify the liquid asset has a teller mapped
        address tellerBefore = address(liquidModule.liquidAssetToTeller(existingLiquidAsset));
        assertEq(tellerBefore, liquidEthTeller);
        
        // Create the array for the function call
        address[] memory assets = new address[](1);
        assets[0] = existingLiquidAsset;
        
        // Expect the LiquidAssetsRemoved event to be emitted
        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModule.LiquidAssetsRemoved(assets);
        
        // Call the function as owner
        vm.prank(owner);
        liquidModule.removeLiquidAsset(assets);
        
        // Verify the liquid asset was unmapped
        address tellerAfter = address(liquidModule.liquidAssetToTeller(existingLiquidAsset));
        assertEq(tellerAfter, address(0));
    }

    // Test removing multiple liquid assets at once
    function test_removeLiquidAsset_worksWithMultipleAssets() public {
        // First, add multiple liquid assets to remove
        address newLiquidAsset1 = address(0x1111111111111111111111111111111111111111);
        address newTeller1 = address(0x1111111111111111111111111111111111111112);
        
        address newLiquidAsset2 = address(0x2222222222222222222222222222222222222222);
        address newTeller2 = address(0x2222222222222222222222222222222222222223);
        
        // Mock the tellers' vault functions
        vm.mockCall(
            newTeller1,
            abi.encodeWithSelector(ILayerZeroTeller.vault.selector),
            abi.encode(newLiquidAsset1)
        );
        
        vm.mockCall(
            newTeller2,
            abi.encodeWithSelector(ILayerZeroTeller.vault.selector),
            abi.encode(newLiquidAsset2)
        );
        
        // Add the new liquid assets
        address[] memory addAssets = new address[](2);
        addAssets[0] = newLiquidAsset1;
        addAssets[1] = newLiquidAsset2;
        
        address[] memory addTellers = new address[](2);
        addTellers[0] = newTeller1;
        addTellers[1] = newTeller2;
        
        vm.prank(owner);
        liquidModule.addLiquidAssets(addAssets, addTellers);
        
        // Verify the liquid assets were added successfully
        assertEq(address(liquidModule.liquidAssetToTeller(newLiquidAsset1)), newTeller1);
        assertEq(address(liquidModule.liquidAssetToTeller(newLiquidAsset2)), newTeller2);
        
        // Now remove the liquid assets
        address[] memory removeAssets = new address[](2);
        removeAssets[0] = newLiquidAsset1;
        removeAssets[1] = newLiquidAsset2;
        
        // Expect the LiquidAssetsRemoved event to be emitted
        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModule.LiquidAssetsRemoved(removeAssets);
        
        // Call the function as owner
        vm.prank(owner);
        liquidModule.removeLiquidAsset(removeAssets);
        
        // Verify the liquid assets were unmapped
        assertEq(address(liquidModule.liquidAssetToTeller(newLiquidAsset1)), address(0));
        assertEq(address(liquidModule.liquidAssetToTeller(newLiquidAsset2)), address(0));
    }

    // Test failure when caller is not an admin
    function test_removeLiquidAsset_revertsWhenNotAdmin() public {
        // Use an existing liquid asset from the setup
        address existingLiquidAsset = address(liquidEth);
        
        // Create the array for the function call
        address[] memory assets = new address[](1);
        assets[0] = existingLiquidAsset;
        
        // Expect the call to revert with Unauthorized
        vm.prank(address(0x123));
        vm.expectRevert(EtherFiLiquidModule.Unauthorized.selector);
        liquidModule.removeLiquidAsset(assets);
    }

    // Test failure when passing an empty array
    function test_removeLiquidAsset_revertsWhenEmptyArray() public {
        // Create an empty array
        address[] memory assets = new address[](0);
        
        // Expect the call to revert with InvalidInput
        vm.prank(owner);
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        liquidModule.removeLiquidAsset(assets);
    }

    // Test removing non-existent liquid assets (should silently succeed)
    function test_removeLiquidAsset_workWithNonExistentAsset() public {
        // Use a non-existent liquid asset
        address nonExistentAsset = address(0x9999999999999999999999999999999999999999);
        
        // Verify the liquid asset doesn't have a teller mapped
        address tellerBefore = address(liquidModule.liquidAssetToTeller(nonExistentAsset));
        assertEq(tellerBefore, address(0));
        
        // Create the array for the function call
        address[] memory assets = new address[](1);
        assets[0] = nonExistentAsset;
        
        // Expect the LiquidAssetsRemoved event to be emitted
        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModule.LiquidAssetsRemoved(assets);
        
        // Call the function as owner
        vm.prank(owner);
        liquidModule.removeLiquidAsset(assets);
        
        // Verify the state remains unchanged
        address tellerAfter = address(liquidModule.liquidAssetToTeller(nonExistentAsset));
        assertEq(tellerAfter, address(0));
    }

    function test_bridge_revertsWhenInsufficientNativeFee() public {
        uint256 amountToBridge = 1 ether;
        deal(address(liquidEth), address(safe), amountToBridge);
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        
        bytes[] memory signatures = new bytes[](2);
        uint256 insufficientFee;

        {
            bytes32 digestHash = keccak256(abi.encodePacked(
                liquidModule.BRIDGE_SIG(),
                block.chainid,
                address(liquidModule),
                safe.nonce(),
                address(safe),
                abi.encode(address(liquidEth), mainnetEid, owner, amountToBridge)
            )).toEthSignedMessageHash();

            uint256 requiredFee = liquidModule.getBridgeFee(address(liquidEth), mainnetEid, owner, amountToBridge);
            insufficientFee = requiredFee - 1; // 1 wei less than required

            (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
            signatures[0] = abi.encodePacked(r, s, v); 
            
            (v, r, s) = vm.sign(owner2Pk, digestHash);
            signatures[1] = abi.encodePacked(r, s, v); 
        }

        vm.expectRevert(EtherFiLiquidModule.InsufficientNativeFee.selector);
        liquidModule.bridge{value: insufficientFee}(address(safe), address(liquidEth), mainnetEid, owner, amountToBridge, owners, signatures);
    }

    function test_bridge_revertsWithInvalidSignatures() public {
        uint256 amountToBridge = 1 ether;
        deal(address(liquidEth), address(safe), amountToBridge);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.BRIDGE_SIG(),
            block.chainid,
            address(liquidModule),
            safe.nonce(),
            address(safe),
            abi.encode(address(liquidEth), mainnetEid, owner, amountToBridge)
        )).toEthSignedMessageHash();

        uint256 fee = liquidModule.getBridgeFee(address(liquidEth), mainnetEid, owner, amountToBridge);

        
        address[] memory owners = new address[](1);
        owners[0] = owner1; // Using valid owner address
        
        bytes[] memory signatures = new bytes[](1);
        // Sign with incorrect private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner2Pk, digestHash);
        signatures[0] = abi.encodePacked(r, s, v);
        
        // Mock the checkSignatures call to return false (invalid signatures)
        vm.mockCall(
            address(safe),
            abi.encodeWithSelector(IEtherFiSafe.checkSignatures.selector),
            abi.encode(false)
        );

        vm.expectRevert(EtherFiLiquidModule.InvalidSignatures.selector);
        liquidModule.bridge{value: fee}(address(safe), address(liquidEth), mainnetEid, owner, amountToBridge, owners, signatures);
    }

    function test_deposit_revertsWhenInvalidSignature() public {
        uint256 amountToDeposit = 1 ether;
        uint256 minReturn = 0.5 ether;
        deal(address(weth), address(safe), amountToDeposit);

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(weth), address(liquidEth), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();

        // Sign with a different private key
        uint256 wrongPrivateKey = 0x54321;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);

        vm.expectRevert(); // Should revert due to ECDSA recovery failure
        liquidModule.deposit(address(safe), address(weth), address(liquidEth), amountToDeposit, minReturn, owner1, invalidSignature);
    }

    function test_deposit_revertsForNonAdminSigner() public {
        uint256 amountToDeposit = 1 ether;
        uint256 minReturn = 0.5 ether;
        deal(address(weth), address(safe), amountToDeposit);
        
        // Create a non-admin address
        address nonAdmin = makeAddr("nonAdmin");

        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.DEPOSIT_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(weth), address(liquidEth), amountToDeposit, minReturn)
        )).toEthSignedMessageHash();

        // Sign with owner1's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory validSignature = abi.encodePacked(r, s, v);

        // Try to use a non-admin signer
        vm.expectRevert();
        liquidModule.deposit(address(safe), address(weth), address(liquidEth), amountToDeposit, minReturn, nonAdmin, validSignature);
    }

    function test_setLiquidAssetWithdrawQueue_succeeds() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModule.LiquidWithdrawQueueSet(address(liquidUsd), address(liquidUsdBoringQueue));
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidUsd), address(liquidUsdBoringQueue));
    }

    function test_setLiquidAssetWithdrawQueue_fails_ifSetterNotRoleRegistryOwner() public {
        vm.prank(makeAddr("alice"));
        vm.expectRevert(EtherFiLiquidModule.Unauthorized.selector);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidUsd), address(liquidUsdBoringQueue));
    }

    function test_setLiquidAssetWithdrawQueue_fails_ifBoringQueueIsNotCorrect() public {
        // putting liquidEth boring queue for liquid USD should fails
        vm.prank(owner);
        vm.expectRevert(EtherFiLiquidModule.InvalidBoringQueue.selector);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidEth), address(liquidUsdBoringQueue));
    }
    
    function test_setLiquidAssetWithdrawQueue_fails_ForZeroAddresses() public {
        vm.startPrank(owner);
        
        vm.expectRevert(EtherFiLiquidModule.InvalidValue.selector);
        liquidModule.setLiquidAssetWithdrawQueue(address(0), address(liquidUsdBoringQueue));
        
        
        vm.expectRevert(EtherFiLiquidModule.InvalidValue.selector);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidUsd), address(0));

        vm.stopPrank();
    }
    
    function test_withdraw_succeeds_forLiquidUsd() public {    
        vm.prank(owner);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidUsd), address(liquidUsdBoringQueue));
        
        uint128 amountToWithdraw = 1000 * 10**6; 
        uint128 amountOut = liquidUsdBoringQueue.previewAssetsOut(address(liquidUsdAssetOut), amountToWithdraw, discount);
        deal(address(liquidUsd), address(safe), amountToWithdraw);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.WITHDRAW_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(liquidUsd), liquidUsdAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        uint256 liquidUsdBalBefore = liquidUsd.balanceOf(address(safe));
        
        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModule.LiquidWithdrawal(address(safe), address(liquidUsd), amountToWithdraw, amountOut);
        
        liquidModule.withdraw(address(safe), address(liquidUsd), liquidUsdAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline, owner1, signature);
        
        uint256 liquidUsdBalAfter = liquidUsd.balanceOf(address(safe));
        assertEq(liquidUsdBalAfter, liquidUsdBalBefore - amountToWithdraw);
    }
    
    function test_withdraw_succeeds_forLiquidEth() public {    
        vm.prank(owner);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidEth), address(liquidEthBoringQueue));
        
        uint128 amountToWithdraw = 1 ether; 
        uint128 assetOut = liquidEthBoringQueue.previewAssetsOut(address(liquidEthAssetOut), amountToWithdraw, discount);
        deal(address(liquidEth), address(safe), amountToWithdraw);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.WITHDRAW_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(liquidEth), liquidEthAssetOut, amountToWithdraw, assetOut, discount, secondsToDeadline)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        uint256 liquidEthBalBefore = liquidEth.balanceOf(address(safe));
        
        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModule.LiquidWithdrawal(address(safe), address(liquidEth), amountToWithdraw, assetOut);
        
        liquidModule.withdraw(address(safe), address(liquidEth), liquidEthAssetOut, amountToWithdraw, assetOut, discount, secondsToDeadline, owner1, signature);
        
        uint256 liquidEthBalAfter = liquidEth.balanceOf(address(safe));
        assertEq(liquidEthBalAfter, liquidEthBalBefore - amountToWithdraw);
    }
    
    function test_withdraw_succeeds_forLiquidBtc() public {    
        vm.prank(owner);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidBtc), address(liquidBtcBoringQueue));
        
        uint128 amountToWithdraw = 1 ether; 
        uint128 assetOut = liquidBtcBoringQueue.previewAssetsOut(address(liquidBtcAssetOut), amountToWithdraw, discount);
        deal(address(liquidBtc), address(safe), amountToWithdraw);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.WITHDRAW_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(liquidBtc), liquidBtcAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        uint256 liquidBtcBalBefore = liquidBtc.balanceOf(address(safe));
        
        vm.expectEmit(true, true, true, true);
        emit EtherFiLiquidModule.LiquidWithdrawal(address(safe), address(liquidBtc), amountToWithdraw, assetOut);
        
        liquidModule.withdraw(address(safe), address(liquidBtc), liquidBtcAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline, owner1, signature);
        
        uint256 liquidBtcBalAfter = liquidBtc.balanceOf(address(safe));
        assertEq(liquidBtcBalAfter, liquidBtcBalBefore - amountToWithdraw);
    }
    
    function test_withdraw_fails_ifReturnAmountIsInsufficient() public {    
        vm.prank(owner);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidBtc), address(liquidBtcBoringQueue));
        
        uint128 amountToWithdraw = 1 ether; 
        uint128 assetOut = liquidBtcBoringQueue.previewAssetsOut(address(liquidBtcAssetOut), amountToWithdraw, discount);
        uint128 minReturn = assetOut + 1;
        deal(address(liquidBtc), address(safe), amountToWithdraw);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.WITHDRAW_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(liquidBtc), address(liquidBtcAssetOut), amountToWithdraw, minReturn, discount, secondsToDeadline)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(EtherFiLiquidModule.InsufficientReturnAmount.selector);
        liquidModule.withdraw(address(safe), address(liquidBtc), liquidBtcAssetOut, amountToWithdraw, minReturn, discount, secondsToDeadline, owner1, signature);
    }

    function test_withdraw_revertsWhenConfigNotSet() public {
        // Use an asset without config
        uint128 amountToWithdraw = 1000 * 10**18;
        deal(address(eUsd), address(safe), amountToWithdraw);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.WITHDRAW_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(eUsd), address(liquidUsdAssetOut), amountToWithdraw, amountToWithdraw, discount, secondsToDeadline)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(EtherFiLiquidModule.LiquidWithdrawConfigNotSet.selector);
        liquidModule.withdraw(address(safe), address(eUsd), liquidUsdAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline, owner1, signature);
    }

    function test_withdraw_revertsWithZeroAmount() public {        
        vm.prank(owner);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidUsd), address(liquidUsdBoringQueue));
        
        uint128 amountToWithdraw = 0;
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.WITHDRAW_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(liquidUsd), liquidUsdAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.InvalidInput.selector);
        liquidModule.withdraw(address(safe), address(liquidUsd), liquidUsdAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline, owner1, signature);
    }

    function test_withdraw_revertsWithInsufficientBalance() public {
        vm.prank(owner);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidUsd), address(liquidUsdBoringQueue));
        
        // Ensure the safe has some balance, but less than we'll try to withdraw
        uint256 safeBalance = 500 * 10**6;
        uint128 amountToWithdraw = 1000 * 10**6; // More than balance
        deal(address(liquidUsd), address(safe), safeBalance);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.WITHDRAW_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(liquidUsd), address(liquidUsdAssetOut), amountToWithdraw, amountToWithdraw, discount, secondsToDeadline)
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(EtherFiLiquidModule.InsufficientBalanceOnSafe.selector);
        liquidModule.withdraw(address(safe), address(liquidUsd), liquidUsdAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline, owner1, signature);
    }

    function test_withdraw_revertsWithInvalidSignature() public {
        vm.prank(owner);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidUsd), address(liquidUsdBoringQueue));
        
        uint128 amountToWithdraw = 1000 * 10**6;
        deal(address(liquidUsd), address(safe), amountToWithdraw);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.WITHDRAW_SIG(),
            block.chainid,
            address(liquidModule),
            liquidModule.getNonce(address(safe)),
            address(safe),
            abi.encode(address(liquidUsd), address(liquidUsdAssetOut), amountToWithdraw + 1, amountToWithdraw, discount, secondsToDeadline) // Wrong amount
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.InvalidSignature.selector);
        liquidModule.withdraw(address(safe), address(liquidUsd), liquidUsdAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline, owner1, invalidSignature);
    }

    function test_withdraw_revertsWhenCalledFromNonSafe() public {
        vm.prank(owner);
        liquidModule.setLiquidAssetWithdrawQueue(address(liquidUsd), address(liquidUsdBoringQueue));
        
        address fakeSafe = makeAddr("fakeSafe");
        uint128 amountToWithdraw = 1000 * 10**6;
        deal(address(liquidUsd), address(fakeSafe), amountToWithdraw);
        
        bytes32 digestHash = keccak256(abi.encodePacked(
            liquidModule.WITHDRAW_SIG(),
            block.chainid,
            address(liquidModule),
            uint256(0), // nonce
            fakeSafe,
            abi.encode(address(liquidUsd), liquidUsdAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline) 
        )).toEthSignedMessageHash();
        
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(owner1Pk, digestHash);
        bytes memory invalidSignature = abi.encodePacked(r, s, v);
        
        vm.expectRevert(ModuleBase.OnlyEtherFiSafe.selector);
        liquidModule.withdraw(address(fakeSafe), address(liquidUsd), liquidUsdAssetOut, amountToWithdraw, amountToWithdraw, discount, secondsToDeadline, owner1, invalidSignature);
    }

    function test_getLiquidAssetWithdrawConfig_returnsCorrectConfig() public view {
        assertEq(liquidModule.getLiquidAssetWithdrawQueue(address(liquidUsd)), address(liquidUsdBoringQueue));
        assertEq(liquidModule.getLiquidAssetWithdrawQueue(address(liquidEth)), address(liquidEthBoringQueue));
        assertEq(liquidModule.getLiquidAssetWithdrawQueue(address(liquidBtc)), address(liquidBtcBoringQueue));
    }
}
