// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {DscEngine} from "../../src/DscEngine.sol";
import {DecentrailizedStableCoin} from "../../src/DecentrailizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

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
        if (block.chainid == 31_337) {
            vm.deal(user, STARTING_USER_BALANCE);
            ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
            ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
        }
    }

    /////////////////////////////////////////////////////////
    //                    Price Tests                      //
    /////////////////////////////////////////////////////////

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

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DscEngine.DscEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    /////////////////////////////////////////////////////////
    //          depositCollateralAndMintDsc Tests          //
    /////////////////////////////////////////////////////////

    /////////////////////////////////////////////////////////
    //                    mintDsc Tests                    //
    /////////////////////////////////////////////////////////

    /////////////////////////////////////////////////////////
    //                    burnDsc Tests                    //
    /////////////////////////////////////////////////////////

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
