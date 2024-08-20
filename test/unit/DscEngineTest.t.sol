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
    address public liquidator = makeAddr("LIQUIDATOR");

    uint256 public constant STARTING_USER_BALANCE = 100 ether;
    uint256 public constant AMOUNT_COLLATERAL = 1 ether;
    uint256 public constant DSC_DEBT_TO_COVER = 10 ether;

    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed collateralToken, uint256 amount
    );

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
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL + 1);
        vm.stopPrank();
    }

    function testRevertsIfTransferFails() public {
        address owner = address(this);

        vm.startPrank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [wethUsdPriceFeed];
        DscEngine mockDscEngine = new DscEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(dscEngine));
        mockDsc.mint(user, STARTING_USER_BALANCE);
        vm.stopPrank();

        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(mockDscEngine), AMOUNT_COLLATERAL);
        mockDscEngine.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DscEngine.DscEngine__TransferFailed.selector);
        mockDscEngine.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public collateralDeposited {
        vm.startPrank(user);
        vm.expectRevert(DscEngine.DscEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public collateralDeposited {
        vm.startPrank(user);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalance = ERC20Mock(address(weth)).balanceOf(user);
        assertEq(STARTING_USER_BALANCE, userBalance);
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public collateralDeposited {
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(user, user, weth, AMOUNT_COLLATERAL);
        vm.startPrank(user);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////
    //           redeemCollateralAndBurnDsctests           //
    /////////////////////////////////////////////////////////

    function testMustRedeemMoreThanZero() public collateralDeposited {
        vm.startPrank(user);
        vm.expectRevert(DscEngine.DscEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateralAndBurnDsc(weth, 0, amountToMint);
    }

    function testCanRedeemCollateralAndBurnDsc() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.redeemCollateralAndBurnDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    /////////////////////////////////////////////////////////
    //                 healthFactor Tests                  //
    /////////////////////////////////////////////////////////

    function testReportHealthFactorProperly() public depositCollateralAndMintDsc {
        // 2000$ collateral, 100$ DSC, health factor = 2000/(2 * 100) = 10
        uint256 healthFactor = dscEngine.getHealthFactor(user);
        assertEq(healthFactor, 10 ether);
    }

    function testHealthFactorCanGoBelowOne() public depositCollateralAndMintDsc {
        // collateral value / dsc amoun * 2 = 2 => health factor = 1
        // 180$ / (100$ * 2) = 0.9
        int256 ethUsdUpdatedPrice = 180e8; // 8 decimals for price feed
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 healthFactor = dscEngine.getHealthFactor(user);
        assertEq(healthFactor, 0.9 ether);
    }

    /////////////////////////////////////////////////////////
    //                 Liquidation Tests                   //
    /////////////////////////////////////////////////////////

    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange setup
        // MockMoreDebtDsc contract will crush the collateral price to 0 while burnning DSC
        MockMoreDebtDsc mockDsc = new MockMoreDebtDsc(wethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [wethUsdPriceFeed];
        address owner = address(this);
        vm.startPrank(owner);
        DscEngine mockDscEngine = new DscEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDscEngine));
        vm.stopPrank();

        // Arrange undercollateralized user
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDscEngine), AMOUNT_COLLATERAL);
        mockDscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Arrange liquidator
        uint256 debtToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, STARTING_USER_BALANCE);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDscEngine), STARTING_USER_BALANCE);
        mockDscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        mockDsc.approve(address(mockDscEngine), debtToCover);

        // Act liquidation
        int256 ethUsdUpdatedPrice = 180e8; // results a health factor of 0.9
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        vm.expectRevert(DscEngine.DscEngine_HealthFactorNotImproved.selector);
        mockDscEngine.liquidate(weth, user, debtToCover);
    }

    function testCantLiquidateGoodHealthFactor() public depositCollateralAndMintDsc {
        ERC20Mock(weth).mint(liquidator, STARTING_USER_BALANCE);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        uint256 userHealthFactor = dscEngine.getHealthFactor(user);

        vm.expectRevert(
            abi.encodeWithSelector(DscEngine.DscEngine__Liquidate__HelthFactorOK.selector, userHealthFactor)
        );
        dscEngine.liquidate(weth, user, amountToMint);
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        int256 updatedEthUsdPrice = 180e8; // // health factor: 180$ / (100$ * 2) = 0.9
        MockV3Aggregator(wethUsdPriceFeed).updateAnswer(updatedEthUsdPrice);

        ERC20Mock(weth).mint(liquidator, STARTING_USER_BALANCE);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL * 4);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL * 4, amountToMint * 2);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, user, amountToMint); // Liquidate all dsc debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayOutCorrectly() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 collateralAmountToLiquidate = dscEngine.getTokenAmountFromUsd(weth, amountToMint);
        // Collateral amount equals debtToCover/CollateralPrice: 100 / 180 = 0.5555
        uint256 liquidationBonus = collateralAmountToLiquidate / 10; // 10% bonus
        // Expected pay out: 0.5555 + 0.05555 = 0.6111
        uint256 expectedPayOut = collateralAmountToLiquidate + liquidationBonus;
        assertEq(liquidatorWethBalance, expectedPayOut + STARTING_USER_BALANCE - AMOUNT_COLLATERAL * 4);
    }

    function testCollateralLeftAfterLiquidation() public liquidated {
        uint256 collateralLeftUsdValue = dscEngine.getAccountCollateralValue(user);
        uint256 collateralLeft = dscEngine.getTokenAmountFromUsd(weth, collateralLeftUsdValue);
        uint256 collateralLiquidated = dscEngine.getTokenAmountFromUsd(weth, amountToMint)
            + (dscEngine.getTokenAmountFromUsd(weth, amountToMint) / 10);
        assertEq(collateralLeft, AMOUNT_COLLATERAL - collateralLiquidated);
    }

    function testLiquidatorTakesOnUserDebt() public liquidated {
        uint256 liquidatorDscBalance = dsc.balanceOf(liquidator); // Should be zero
        (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(liquidator);
        assertEq(liquidatorDscBalance + amountToMint, liquidatorDscMinted);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }

    /////////////////////////////////////////////////////////
    //              View & Pure Function Tests             //
    /////////////////////////////////////////////////////////

    function testGetCollateralTokenPricefeed() public view {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, wethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dscEngine.getMinHealthFactor();
        assertEq(minHealthFactor, 1e18);
    }

    function testGetAccountCollateralValueFromInformation() public collateralDeposited {
        (, uint256 collateralValue) = dscEngine.getAccountInformation(user);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public collateralDeposited {
        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL);
    }

    function testGetAccountCollateralValue() public collateralDeposited {
        uint256 collateralValue = dscEngine.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }
}
