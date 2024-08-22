// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

contract DscEngine is ReentrancyGuard {
    /////////////////////////////////////////////////////////
    //                       Errors                        //
    /////////////////////////////////////////////////////////

    error DscEngine__NeedsMoreThanZero();
    error DscEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
    error DscEngine__TokenNotAllowed(address tokenAddress);
    error DscEngine__TransferFailed();
    error DscEngine__BreakHealthFactor(uint256 healthFactorValue);
    error DscEngine__MintFailed();
    error DscEngine__Liquidate__HealthFactorOK(uint256 healthFactorValue);
    error DscEngine_HealthFactorNotImproved();

    /////////////////////////////////////////////////////////
    //                       Types                         //
    /////////////////////////////////////////////////////////

    using OracleLib for AggregatorV3Interface;

    /////////////////////////////////////////////////////////
    //                  State Variables                    //
    /////////////////////////////////////////////////////////

    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant LIQUIDATION_PRECISION = 100; // means you need to be 200% over-collateralized
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant FEED_PRECISION = 1e8;

    //@dev Mapping of token address to price feed address
    mapping(address token => address priceFeed) private s_priceFeed;
    //@dev Amount of collateral deposited by a user
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDeposited;
    //@dev Amount of DSC minted by a user
    mapping(address user => uint256 dscMinted) private s_dscMinted;
    //@dev If we know how many collateral tokens are available, we could make this immutable
    address[] private s_collateralTokens;

    /////////////////////////////////////////////////////////
    //                      Events                         //
    /////////////////////////////////////////////////////////

    event CollateralDeposited(address indexed user, address indexed collateralToken, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed collateralToken, uint256 amount
    );

    /////////////////////////////////////////////////////////
    //                     Modifiers                       //
    /////////////////////////////////////////////////////////

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert DscEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address _tokenAddress) {
        if (s_priceFeed[_tokenAddress] == address(0)) {
            revert DscEngine__TokenNotAllowed(_tokenAddress);
        }
        _;
    }

    /////////////////////////////////////////////////////////
    //                    Functions                        //
    /////////////////////////////////////////////////////////

    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses, address _dscAddress) {
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DscEngine__TokenAddressesAndPriceFeedAddressesLengthMismatch();
        }
        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeed[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(_dscAddress);
    }

    /////////////////////////////////////////////////////////
    //                External Functions                   //
    /////////////////////////////////////////////////////////

    function depositCollateralAndMintDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint);
    }

    /**
     * @notice This function will withdraw your collateral and burn DSC in one transaction
     * @param _tokenCollateralAddress : The ERC20 token address of the collateral you're depositing
     * @param _amountCollateral : The amount of collateral you're depositing
     * @param _amountDscToBurn : The amount of DSC you want to burn
     */
    function redeemCollateralAndBurnDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) external moreThanZero(_amountCollateral) {
        _burnDsc(_amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender, _tokenCollateralAddress, _amountCollateral);
        _revertIfHealthFactorIsBrocken(msg.sender);
    }

    /**
     * @notice Redeems collateral
     * @param _tokenCollateralAddress The address of the collateral token
     * @param _amountCollateral The amount of collateral to redeem
     */
    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        external
        moreThanZero(_amountCollateral)
        nonReentrant
        isAllowedToken(_tokenCollateralAddress)
    {
        _redeemCollateral(msg.sender, msg.sender, _tokenCollateralAddress, _amountCollateral);
        _revertIfHealthFactorIsBrocken(msg.sender);
    }

    /**
     * @notice careful! You'll burn your DSC here! Make sure you want to do this...
     * @dev you might want to use this if you're nervous you might get liquidated
     *      and ant to just burn your DSC to keep your collateral
     * @param _amountDsc The amount of DSC to burn
     */
    function burnDsc(uint256 _amountDsc) external moreThanZero(_amountDsc) nonReentrant {
        _burnDsc(_amountDsc, msg.sender, msg.sender);
    }

    /**
     * @notice this function allowes a user to liquidate another user who's undercollateralized
     *         and receives a 10% liquidation bonus of the collateral value being liquidated
     * @param _collateralTokenAddress the address of the collateral token that will be liquidated
     * @param _userUndercollateralized the address of the user who's undercollateralized
     * @param _DscDebtTocover the amount of DSC debt that will be covered by the liquidation
     *        (You can partially liquidate a user by specifying a smaller amount than their total debt)
     */
    function liquidate(address _collateralTokenAddress, address _userUndercollateralized, uint256 _DscDebtTocover)
        external
        moreThanZero(_DscDebtTocover)
        nonReentrant
    {
        // Check if the user being liquidated is actually undercollateralized
        uint256 startingHealthFactor = _getHealthFactor(_userUndercollateralized);
        if (startingHealthFactor > MIN_HEALTH_FACTOR) {
            revert DscEngine__Liquidate__HealthFactorOK(startingHealthFactor);
        }

        // Calculate the amount of collateral that will be liquidated, which equals _DscDebtTocover in USD value
        uint256 collateralAmountToLiquidate = getTokenAmountFromUsd(_collateralTokenAddress, _DscDebtTocover);
        uint256 bonusCollateral = collateralAmountToLiquidate * LIQUIDATION_BONUS / LIQUIDATION_PRECISION;

        // Redeem collateral from undercollateralized user to the liquidator
        _redeemCollateral(
            _userUndercollateralized, msg.sender, _collateralTokenAddress, collateralAmountToLiquidate + bonusCollateral
        );
        // Burn DSC from the liquidator and clean the debt from the undercollateralized user
        _burnDsc(_DscDebtTocover, _userUndercollateralized, msg.sender);

        // Check if the health factor of the undercollateralized user has improved
        uint256 endingHealthFactor = _getHealthFactor(_userUndercollateralized);
        if (endingHealthFactor <= startingHealthFactor) {
            revert DscEngine_HealthFactorNotImproved();
        }
        // Make sure the liquidation process doesn't break the health factor of the liquidator
        _revertIfHealthFactorIsBrocken(msg.sender);
    }

    /////////////////////////////////////////////////////////
    //                  Public Functions                   //
    /////////////////////////////////////////////////////////

    /**
     * @notice You can mint DSC if you have enough collateral deposited
     * @notice Follows CEI: Check(with modifier), Effect, Interact
     * @param _amountDscToMint The amount of DSC to mint
     */
    function mintDsc(uint256 _amountDscToMint) public moreThanZero(_amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += _amountDscToMint;
        _revertIfHealthFactorIsBrocken(msg.sender);
        bool isMinted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!isMinted) {
            revert DscEngine__MintFailed();
        }
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

    /////////////////////////////////////////////////////////
    //                 Private Functions                   //
    /////////////////////////////////////////////////////////

    /**
     * @notice Redeem collateral from the DSC Engine
     * @param redeemedFrom address of the account that it's deposited collateral will be redeemed
     * @param redeemedTo address of the account that will receive the collateral
     * @param _tokenCollateralAddress address of the collateral token
     * @param _amountCollateral amount of collateral to be redeemed
     */
    function _redeemCollateral(
        address redeemedFrom,
        address redeemedTo,
        address _tokenCollateralAddress,
        uint256 _amountCollateral
    ) private {
        s_collateralDeposited[redeemedFrom][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedeemed(redeemedFrom, redeemedTo, _tokenCollateralAddress, _amountCollateral);
        // transfer
        bool success = IERC20(_tokenCollateralAddress).transfer(redeemedTo, _amountCollateral);
        if (!success) {
            revert DscEngine__TransferFailed();
        }
    }

    /**
     * @notice Burn DSC from the DSC Engine
     * @param _amountDscToBurn amount of DSC to be burned
     * @param onBehalfOf address of the account that's gonna reduce the dsc debt from s_dscMinted[]
     * @param dscFrom address of the account that will actually burn the DSC
     */
    function _burnDsc(uint256 _amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= _amountDscToBurn;
        // transfer DSC to contract first
        bool success = i_dsc.transferFrom(dscFrom, address(this), _amountDscToBurn);
        if (!success) {
            revert DscEngine__TransferFailed();
        }
        i_dsc.burn(_amountDscToBurn);
    }

    ////////////////////////////////////////////////////////////////////////////
    //             Private & Internal View & Pure Functions                   //
    ////////////////////////////////////////////////////////////////////////////

    function _revertIfHealthFactorIsBrocken(address _user) internal view {
        uint256 userHealthFactor = _getHealthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DscEngine__BreakHealthFactor(userHealthFactor);
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

    /**
     * @notice healthFactor = (1/2 collateralValue) / DscMinted => 200% over-collateral
     * @param _totalDscMinted total DSC minted by a user in WEI
     * @param _collateralValueInUsd USD value of a user's collateral in WEI
     */
    function _calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        private
        pure
        returns (uint256)
    {
        if (_totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (_collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / _totalDscMinted;
    }

    /**
     * @notice Get the USD value of a token
     * @param _tokenAddress address of the token to get the USD value
     * @param _amount amount of the token in WEI
     * @return uint256 USD value of the token (with 18 decimal places)
     */
    function _getUsdValue(address _tokenAddress, uint256 _amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[_tokenAddress]);
        // Returned price has 8 decimal places
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // Return the price of WEI (1 ETH = 1e18 WEI), so adding 10 more decimal places
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * _amount) / PRECISION;
    }

    ////////////////////////////////////////////////////////////////////////////
    //              Public & External View & Pure Functions                   //
    ////////////////////////////////////////////////////////////////////////////

    function calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(_totalDscMinted, _collateralValueInUsd);
    }

    /**
     * @notice Get the total collateral value of a user in USD
     * @param _user address of the user to get the collateral value
     */
    function getAccountCollateralValue(address _user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address tokenAddress = s_collateralTokens[i];
            uint256 collateralAmount = s_collateralDeposited[_user][tokenAddress];
            totalCollateralValueInUsd += _getUsdValue(tokenAddress, collateralAmount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address _tokenAddress, uint256 _amount) external view returns (uint256) {
        return _getUsdValue(_tokenAddress, _amount);
    }

    /**
     * @notice This function calculates the amount of a specific token equivalent to a given USD value.
     * @param _tokenAddress: The ERC20 token address whose equivalent amount is to be calculated.
     * @param _usdValueInWei: The amount of USD (in Wei) that needs to be converted to the equivalent token amount.
     * @return The amount of the token that corresponds to the given USD value, taking into account the token's price.
     */
    function getTokenAmountFromUsd(address _tokenAddress, uint256 _usdValueInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[_tokenAddress]);
        if (address(priceFeed) == address(0)) {
            revert DscEngine__TokenNotAllowed(_tokenAddress);
        }
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return (_usdValueInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address _user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(_user);
    }

    function getHealthFactor(address _user) external view returns (uint256) {
        return _getHealthFactor(_user);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeed[token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }
}
