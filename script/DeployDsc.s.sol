// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DscEngine} from "../src/DscEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDsc is Script {
    address[] tokenAddress;
    address[] priceFeedAddress;

    function run() external returns (DecentralizedStableCoin, DscEngine, HelperConfig) {
        // Prepare network config
        HelperConfig helperConfig = new HelperConfig();
        (address wethAddress, address wbtcAddress, address wethPriceFeed, address wbtcPriceFeed, uint256 deployerKey) =
            helperConfig.activeNetworkConfig();
        tokenAddress = [wethAddress, wbtcAddress];
        priceFeedAddress = [wethPriceFeed, wbtcPriceFeed];

        // Deploy DSC and DSCEngine
        vm.startBroadcast(deployerKey);
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        DscEngine engine = new DscEngine(tokenAddress, priceFeedAddress, address(dsc));
        dsc.transferOwnership(address(engine));
        vm.stopBroadcast();
        return (dsc, engine, helperConfig);
    }
}
