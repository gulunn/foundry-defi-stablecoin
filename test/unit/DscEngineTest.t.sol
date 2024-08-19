// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DscEngine} from "../../src/DscEngine.sol";
import {DecentrailizedStableCoin} from "../../src/DecentrailizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDsc} from "../mocks/MockFailedMintDsc.sol";
import {MockMoreDebtDsc} from "../mocks/MockMoreDebtDsc.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DscEngineTest is Test {
    DscEngine dscEngine;
    DecentrailizedStableCoin dsc;
    HelperConfig helperConfig;
    DeployDsc deployer;

    address weth;
    address wbtc;
    address wethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    uint256 deployerKey;

    uint256 amountToMint = 100 ether;
    address public user = makeAddr("USER");

    uint256 public constant STARTING_USER_BALANCE = 100 ether;
    uint256 public constant AMOUNT_COLLATERAL = 1 ether;

    function setUp() public {
        deployer = new DeployDsc();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (weth, wbtc, wethUsdPriceFeed, wbtcUsdPriceFeed, deployerKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31337) {
            vm.deal(user, STARTING_USER_BALANCE);
            ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
            ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
        }
    }

    /////////////////////////////////////////////////////////
    //                 Constructor Tests                   //
    /////////////////////////////////////////////////////////
    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function testRevertIfTokenAndPriceFeedAddressesDoesntMatch() public {
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed];
        vm.expectRevert(DscEngine.DscEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch.selector);
        new DscEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }
    /////////////////////////////////////////////////////////
    //                    Price Tests                      //
    /////////////////////////////////////////////////////////

    function testGetTokenAmountFromUsd() public view {
        // Get 100$ worth of WETH (weth/usd = 2000) => Should be 0.05 WETH
        uint256 expectedWethAmount = 0.05 ether;
        uint256 actualWethAmount = dscEngine.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(actualWethAmount, expectedWethAmount);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 eth * 2000 eth/usd = 30000e18 usd
        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(actualUsdValue, expectedUsdValue);
    }

    /////////////////////////////////////////////////////////
    //              depositCollateral Tests                //
    /////////////////////////////////////////////////////////

    modifier collateralDeposited() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [wethUsdPriceFeed];
        vm.prank(owner);
        DscEngine mockDsce = new DscEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(user, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce)); // Make mockDscEngine the owner of the mockDsc contract
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        vm.expectRevert(DscEngine.DscEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DscEngine.DscEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, STARTING_USER_BALANCE);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(DscEngine.DscEngine__TokenNotAllowed.selector, address(randToken)));
        dscEngine.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralWithoutMinting() public collateralDeposited {
        uint256 bal = dsc.balanceOf(user);
        assertEq(bal, 0);
    }

    function testCanDepositCollateralAndGetAccountInfoCorrectly() public collateralDeposited {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(user);
        uint256 expectedCollateralAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedCollateralAmount, AMOUNT_COLLATERAL);
    }

    /////////////////////////////////////////////////////////
    //          depositCollateralAndMintDsc Tests          //
    /////////////////////////////////////////////////////////

    function testRevertsIfMintDscBreaksHelthFactor() public {
        uint256 collateralValuedInUsd = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        amountToMint = collateralValuedInUsd; // This amountToMint should break the health factor

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(amountToMint, collateralValuedInUsd);
        vm.expectRevert(abi.encodeWithSelector(DscEngine.DscEnging__BreakHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    modifier depositCollateralAndMintDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        _;
    }

    function testCanMintDscWithDepositedCollateral() public depositCollateralAndMintDsc {
        uint256 bal = dsc.balanceOf(user);
        assertEq(bal, amountToMint);
    }

    /////////////////////////////////////////////////////////
    //                    mintDsc Tests                    //
    /////////////////////////////////////////////////////////

    function testRevertsIfMintFails() public {
        // Need a mocked dsc contract to make mint failed
        MockFailedMintDsc mockDsc = new MockFailedMintDsc();
        address owner = address(this);
        tokenAddresses = [weth];
        priceFeedAddresses = [wethUsdPriceFeed];
        // Make mockDscEngine the owner of the mockDsc contract
        vm.startPrank(owner);
        DscEngine mockDscEngine = new DscEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDscEngine));
        vm.stopPrank();

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DscEngine.DscEnging__MintFailed.selector);
        mockDscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.expectRevert(DscEngine.DscEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public {
        //Let mint value = collateral value, which breaks health factor
        amountToMint = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        // equals 0.5e18, 50% undercollateralized (because the threshold is twice the collateral value)
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(amountToMint, amountToMint);

        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(abi.encodeWithSelector(DscEngine.DscEnging__BreakHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public collateralDeposited {
        vm.startPrank(user);
        dscEngine.mintDsc(amountToMint);
        uint256 userDscBalance = dsc.balanceOf(user);
        assertEq(userDscBalance, amountToMint);
    }

    /////////////////////////////////////////////////////////
    //                    burnDsc Tests                    //
    /////////////////////////////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        // moreThanZero modifier happens before the burnDsc function, so we don't need to deposit and mint first
        vm.expectRevert(DscEngine.DscEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanBalance() public {
        vm.startPrank(user);
        vm.expectRevert();
        dscEngine.burnDsc(1);
    }

    function testCanBurnDsc() public depositCollateralAndMintDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.burnDsc(amountToMint);
        vm.stopPrank();
        uint256 userDscBalance = dsc.balanceOf(user);
        assertEq(userDscBalance, 0);
    }

    /////////////////////////////////////////////////////////
    //               redeemCollateral Tests                //
    /////////////////////////////////////////////////////////

    function testCollateralDepositedCantBelowZero() public {
        vm.startPrank(user);
        console.log("user weth balance: ", ERC20Mock(weth).balanceOf(user));
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        console.log("collateral deposited");
        vm.expectRevert();
        vm.expectRevert();
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL + 1);
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////
    //            redeemCollateralForDsc Tests             //
    /////////////////////////////////////////////////////////

    /////////////////////////////////////////////////////////
    //                 healthFactor Tests                  //
    /////////////////////////////////////////////////////////

    /////////////////////////////////////////////////////////
    //            View & Pure Function Tests               //
    /////////////////////////////////////////////////////////
}
