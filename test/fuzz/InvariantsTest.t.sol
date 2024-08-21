// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDsc} from "../../script/DeployDsc.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DscEngine} from "../../src/DscEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDsc deployer;
    HelperConfig helperConfig;
    DscEngine dscEngine;
    DecentralizedStableCoin dsc;

    function setUp() external {
        deployer = new DeployDsc();
        (dsc, dscEngine, helperConfig) = deployer.run();
    }
}
