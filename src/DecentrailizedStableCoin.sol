// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentrailizedStableCoin
 * @author LiuZichen
 * Collateral: Exogenous
 * Minting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral Type: Crypto
 * This is the contract meant to be owned by DSCEngine. It is a ERC20 token that can be minted and burned by the
 * DSCEngine smart contract.
 */
contract DecentrailizedStableCoin is ERC20Burnable, Ownable {
    error DecentrailizedStableCoin__NotZeroAddreses();
    error DecentrailizedStableCoin__AmountLessThanZero();
    error DecentrailizedStableCoin__BurnAmountExceedsBalance();

    constructor() ERC20("DecentrailizedStableCoin", "DSC") {}

    function burn(uint256 _amount) public override onlyOwner {
        if (_amount <= 0) {
            revert DecentrailizedStableCoin__AmountLessThanZero();
        }
        if (_amount > balanceOf(msg.sender)) {
            revert DecentrailizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentrailizedStableCoin__NotZeroAddreses();
        }
        if (_amount < 0) {
            revert DecentrailizedStableCoin__AmountLessThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
