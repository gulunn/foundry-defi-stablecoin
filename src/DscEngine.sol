// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentrailizedStableCoin} from "./DecentrailizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DscEngine is ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////
    error DscEngine__NeedsMoreThanZero();
    error DscEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
    error DscEngine__TokenNotAllowed();
    error DscEngine__TransferFailed();
    error DscEnging__BreakHealthFactor();

    ///////////////////
    // Types
    ///////////////////

    ///////////////////
    // State Variables
    ///////////////////
    DecentrailizedStableCoin private immutable i_dsc;

    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    //@dev Mapping of token address to price feed address
    mapping(address token => address priceFeed) private s_priceFeed;
    //@dev Amount of collateral deposited by a user
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    //@dev Amount of DSC minted by a user
    mapping(address user => uint256 dscMinted) private s_dscMinted;
    //@dev If we know how many collateral tokens are available, we could make this immutable
    address[] private s_collateralTokens;
    ///////////////////
    // Events
    ///////////////////

    event CollateralDeposited(address indexed user, address indexed collateralToken, uint256 indexed amount);

    ///////////////////
    // Modifiers
    ///////////////////
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DscEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (s_priceFeed[_tokenAddress] == address(0)) {
            revert DscEngine__TokenNotAllowed();
        }
        _;
    }

    ///////////////////
    // Functions
    ///////////////////
    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address _dscAddress) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DscEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
        }
        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeed[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_dsc = DecentrailizedStableCoin(_dscAddress);
    }

    ///////////////////////
    // External Functions
    ///////////////////////
    function depositCollateralAndMintDsc() external {}

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    function burnDsc() external {}

    function liquidate() external {}

    ///////////////////////
    // Public Functions
    ///////////////////////

    /**
     * @notice You can mint DSC if you have enough collateral deposited
     * @notice Follows CEI: Check(with modifier), Effect, Interact
     * @param _amountDscToMint The amount of DSC to mint
     */
    function mintDsc(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBrocken(msg.sender);
    }

    /**
     * @notice Deposit collateral to the DSC Engine
     * @notice Follows CEI: Check(with modifier), Effect, Interact
     * @dev This function will be called by the DSC contract
     *
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amount)
        public
        moreThanZero(_amount)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amount;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amount);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert DscEngine__TransferFailed();
        }
    }

    ///////////////////////
    // Private Functions
    ///////////////////////

    ////////////////////////////////////////////////////////////////////////////
    // Private & Internal View & Pure Functions
    ////////////////////////////////////////////////////////////////////////////
    function _revertIfHealthFactorIsBrocken(address _user) internal view {
        uint256 userHealthFactor = _getHealthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DscEnging__BreakHealthFactor();
        }
    }

    function _getHealthFactor(address _user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(_user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _getAccountInformation(address _user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[_user];
        collateralValueInUsd = getAccountCollateralValue(_user);
    }

    function _calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        private
        view
        returns (uint256)
    {}

    ////////////////////////////////////////////////////////////////////////////
    // Public & External View & Pure Functions
    ////////////////////////////////////////////////////////////////////////////
    function calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        external
        view
        returns (uint256)
    {
        return _calculateHealthFactor(_totalDscMinted, _collateralValueInUsd);
    }

    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address tokenAddress = s_collateralTokens[i];
            uint256 collateralAmount = s_collateralDeposited[_user][tokenAddress];
            totalCollateralValueInUsd += _getUsdValue(tokenAddress, collateralAmount);
        }
        return totalCollateralValueInUsd;
    }
}
