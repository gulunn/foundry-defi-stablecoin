// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;
    uint256 public constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    struct NetworkConfig {
        address wethAddress;
        address wbtcAddress;
        address wethPriceFeed;
        address wbtcPriceFeed;
        uint256 deployerKey;
    }

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        }
        if (block.chainid == 31337) {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wethAddress: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wbtcAddress: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            wethPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wbtcPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            deployerKey: vm.envUint("SEPOLIA_PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wethPriceFeed != address(0)) {
            return activeNetworkConfig;
        }
        // Deploying mocks
        vm.startBroadcast();
        MockV3Aggregator wethPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        MockV3Aggregator wbtcPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);
        ERC20Mock weth = new ERC20Mock("WETH", "WETH", address(this), 1000e8);
        ERC20Mock wbtc = new ERC20Mock("WBTC", "WBTC", address(this), 1000e8);
        vm.stopBroadcast();

        return NetworkConfig({
            wethAddress: address(weth),
            wbtcAddress: address(wbtc),
            wethPriceFeed: address(wethPriceFeed),
            wbtcPriceFeed: address(wbtcPriceFeed),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}
