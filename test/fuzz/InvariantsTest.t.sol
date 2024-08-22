// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DscEngine} from "../../src/DscEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDsc deployer;
    HelperConfig helperConfig;
    DscEngine dscEngine;
    DecentralizedStableCoin dsc;

    address wethAddress;
    address wbtcAddress;

    function setUp() external {
        deployer = new DeployDsc();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (wethAddress, wbtcAddress,,,) = helperConfig.activeNetworkConfig();
        Handler handler = new Handler(dsc, dscEngine);
        // Set the target contract for the invariant checks
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() external view {
        uint256 totalSupply = dsc.totalSupply();

        uint256 totalWethDeposited = IERC20(wethAddress).balanceOf(address(dscEngine));
        uint256 totalWbtcDeposited = IERC20(wbtcAddress).balanceOf(address(dscEngine));
        uint256 totalWethValue = dscEngine.getUsdValue(wethAddress, totalWethDeposited);
        uint256 totalWbtcValue = dscEngine.getUsdValue(wbtcAddress, totalWbtcDeposited);

        console.log("weth value:", totalWethValue);
        console.log("wbtc value:", totalWbtcValue);
        console.log("total supply:", totalSupply);

        assert(totalSupply <= totalWethValue + totalWbtcValue);
    }

    function invariant_gettersShouldNotRevert() public view {
        dscEngine.getCollateralTokens();
        dscEngine.getMinHealthFactor();
    }
}
