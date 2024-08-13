// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {DecentrailizedStableCoin} from "../src/DecentrailizedStableCoin.sol";
import {DscEngine} from "../src/DscEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDsc is Script {
    address[] tokenAddress;
    address[] priceFeedAddress;

    function run() external returns (DecentrailizedStableCoin, DscEngine, HelperConfig) {
        // Prepare network config
        HelperConfig helperConfig = new HelperConfig();
        (address wethAddress, address wbtcAddress, address wethPriceFeed, address wbtcPriceFeed, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        tokenAddress = [wethAddress, wbtcAddress];
        priceFeedAddress = [wethPriceFeed, wbtcPriceFeed];

        // Deploy DSC and DSCEngine
        vm.startBroadcast(deployerKey);
        DecentrailizedStableCoin dsc = new DecentrailizedStableCoin();
        DscEngine engine = new DscEngine(tokenAddress, priceFeedAddress, address(dsc));
        dsc.transferOwnership(address(engine));
        vm.stopBroadcast();
        return (dsc, engine, helperConfig);
    }
}
