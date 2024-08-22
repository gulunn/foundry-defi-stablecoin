// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DscEngine} from "../../src/DscEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DscEngine dscEngine;
    ERC20Mock weth;
    ERC20Mock wbtc;

    address[] userDeposited;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DecentralizedStableCoin _dsc, DscEngine _dscEngine) {
        dsc = _dsc;
        dscEngine = _dscEngine;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(address(msg.sender));
        collateral.mint(address(msg.sender), amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        // Record user deposited
        userDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(msg.sender, address(collateral));
        console.log("collateralBalance", collateralBalance);
        // delete this
        // TODO: redeemCollateral only checks if user has enough collateral, but not if they have minted dsc
        // so that they could break health factor if they redeem all collateral
        (uint256 dscMinted, uint256 collateralValue) = dscEngine.getAccountInformation(msg.sender);
        console.log("dscMinted", dscMinted);
        console.log("collateralValue", collateralValue);

        amountCollateral = bound(amountCollateral, 0, collateralBalance);
        // If the amount is 0, we skip this fuzz run
        if (amountCollateral == 0) return;
        vm.prank(msg.sender);
        dscEngine.redeemCollateral(address(collateral), amountCollateral);
    }

    // function mintDsc(uint256 _amount, uint256 _addressSeed) public {
    //     if (userDeposited.length == 0) return;
    //     console.log("user array length", userDeposited.length);
    //     address userAddress = userDeposited[_addressSeed % userDeposited.length];
    //     (uint256 dscMinted, uint256 collateralValue) = dscEngine.getAccountInformation(userAddress);
    //     uint256 maxDscToMint = (collateralValue / 2) - dscMinted;
    //     if (maxDscToMint <= 0) return;
    //     _amount = bound(_amount, 0, maxDscToMint);
    //     if (_amount == 0) return;
    //     vm.prank(userAddress);
    //     dscEngine.mintDsc(_amount);
    // }

    /////////////////////////////////////////////////////////
    //                  Helper functions                   //
    /////////////////////////////////////////////////////////
    function _getCollateralFromSeed(uint256 seed) internal view returns (ERC20Mock) {
        if (seed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
