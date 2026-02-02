// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterBase} from "./base/AdapterBase.sol";
import {IMToken} from "../interfaces/IMToken.sol";
import {IMoonwellComptroller} from "../interfaces/IMoonwellComptroller.sol";

/// @title MoonwellAdapter
/// @notice Adapter for managing Moonwell (Compound V2 fork) markets on Base
/// @dev Implements the ILendingAdapter interface for Moonwell protocol
contract MoonwellAdapter is AdapterBase {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    /// @notice Thrown when the mToken address is zero
    error InvalidMTokenAddress();

    /// @notice Thrown when the comptroller address is zero
    error InvalidComptrollerAddress();

    /// @notice Thrown when mint operation fails
    error MintFailed(uint256 errorCode);

    /// @notice Thrown when redeem operation fails
    error RedeemFailed(uint256 errorCode);

    /// @notice Thrown when the mToken is not listed in the comptroller
    error MarketNotListedInComptroller();

    /// @notice Configuration for a single Moonwell market
    struct MarketConfig {
        Currency currency;
        address mToken; // mToken address for this market (e.g., mUSDC)
        bool active;
    }

    /// @notice The Moonwell Comptroller
    IMoonwellComptroller public immutable COMPTROLLER;

    /// @notice Maps marketId to market configuration
    mapping(bytes32 marketId => MarketConfig) public markets;

    /// @notice Emitted when a new market is registered
    event MarketRegistered(bytes32 indexed marketId, Currency currency, address mToken);

    /// @notice Emitted when a market is deactivated
    event MarketDeactivated(bytes32 indexed marketId);

    /// @notice Emitted when a deposit is made to Moonwell
    event DepositedToMoonwell(bytes32 indexed marketId, uint256 amount, address onBehalfOf);

    /// @notice Emitted when a withdrawal is made from Moonwell
    event WithdrawnFromMoonwell(bytes32 indexed marketId, uint256 amount, address to);

    /// @notice Constructor
    /// @param _comptroller The address of the Moonwell Comptroller
    /// @param initialOwner The initial owner of the adapter (can register markets)
    constructor(address _comptroller, address initialOwner) AdapterBase(initialOwner) {
        if (_comptroller == address(0)) revert InvalidComptrollerAddress();
        COMPTROLLER = IMoonwellComptroller(_comptroller);
    }

    /// @notice Registers a new market in this adapter
    /// @dev Only the adapter owner can register markets
    /// @param currency The underlying currency for this market
    /// @param mToken The mToken address for this market
    function registerMarket(Currency currency, address mToken) external onlyOwner validCurrency(currency) {
        if (mToken == address(0)) revert InvalidMTokenAddress();

        // Verify mToken is listed in the comptroller
        if (!_isMarketListed(mToken)) revert MarketNotListedInComptroller();

        // Verify mToken matches currency
        address underlyingFromMToken = IMToken(mToken).underlying();
        if (Currency.unwrap(currency) != underlyingFromMToken) revert AssetMismatch();

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 marketId = keccak256(abi.encode(currency));
        if (markets[marketId].active) revert MarketAlreadyRegistered();

        markets[marketId] = MarketConfig({currency: currency, mToken: mToken, active: true});

        emit MarketRegistered(marketId, currency, mToken);
    }

    /// @notice Deactivates a market
    /// @dev Only the adapter owner can deactivate markets
    /// @param marketId The market identifier to deactivate
    function deactivateMarket(bytes32 marketId) external onlyOwner {
        if (!markets[marketId].active) revert MarketNotActive();
        markets[marketId].active = false;
        emit MarketDeactivated(marketId);
    }

    /// @notice Returns the metadata for this lending adapter
    /// @return metadata The adapter metadata containing name and chainId
    function getAdapterMetadata() external view override returns (AdapterMetadata memory metadata) {
        return AdapterMetadata({name: "Moonwell", chainId: block.chainid});
    }

    /// @notice Checks if a market is registered and active
    /// @param marketId The market identifier
    /// @return True if the market is registered and active
    function hasMarket(bytes32 marketId) external view override returns (bool) {
        return markets[marketId].active;
    }

    /// @notice Deposits tokens into Moonwell
    /// @param marketId The market identifier
    /// @param amount The amount to deposit
    /// @param onBehalfOf The address that will receive the mTokens
    function deposit(bytes32 marketId, uint256 amount, address onBehalfOf)
        external
        override
        validDepositWithdrawParams(amount, onBehalfOf)
    {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();

        address tokenAddress = Currency.unwrap(config.currency);
        IMToken mToken = IMToken(config.mToken);

        // Transfer tokens from caller to this adapter
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);

        // Approve mToken to spend tokens
        IERC20(tokenAddress).forceApprove(config.mToken, amount);

        // Mint mTokens (Compound V2 style)
        uint256 mintResult = mToken.mint(amount);
        if (mintResult != 0) revert MintFailed(mintResult);

        // Transfer mTokens to the recipient
        uint256 mTokenBalance = IERC20(config.mToken).balanceOf(address(this));
        IERC20(config.mToken).safeTransfer(onBehalfOf, mTokenBalance);

        emit DepositedToMoonwell(marketId, amount, onBehalfOf);
    }

    /// @notice Withdraws tokens from Moonwell
    /// @param marketId The market identifier
    /// @param amount The amount of mTokens to redeem (mTokens are ERC20)
    /// @param to The address that will receive the withdrawn tokens
    /// @dev The hook transfers mTokens to this adapter before calling withdraw
    function withdraw(bytes32 marketId, uint256 amount, address to)
        external
        override
        onlyAuthorizedCaller
        validDepositWithdrawParams(amount, to)
        returns (uint256)
    {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();

        IMToken mToken = IMToken(config.mToken);

        // mTokens have already been transferred to this adapter by the hook
        uint256 redeemResult = mToken.redeem(amount);
        if (redeemResult != 0) revert RedeemFailed(redeemResult);

        // Transfer the underlying tokens to the recipient
        // Get actual balance to account for exchange rate differences
        uint256 underlyingBalance = IERC20(Currency.unwrap(config.currency)).balanceOf(address(this));
        IERC20(Currency.unwrap(config.currency)).safeTransfer(to, underlyingBalance);

        emit WithdrawnFromMoonwell(marketId, underlyingBalance, to);

        return underlyingBalance;
    }

    /// @notice Returns the yield-bearing token address for a given market
    /// @param marketId The market identifier
    /// @return The address of the corresponding mToken
    function getYieldToken(bytes32 marketId) external view override returns (address) {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();
        return config.mToken;
    }

    /// @notice Returns the underlying currency for a given market
    /// @param marketId The market identifier
    /// @return The underlying currency of the market
    function getMarketCurrency(bytes32 marketId) external view override returns (Currency) {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();
        return config.currency;
    }

    /// @notice Checks if an mToken is listed in the comptroller
    /// @param mToken The mToken address to check
    /// @return True if the mToken is in the comptroller's market list
    function _isMarketListed(address mToken) internal view returns (bool) {
        address[] memory allMarkets = COMPTROLLER.getAllMarkets();
        for (uint256 i = 0; i < allMarkets.length; i++) {
            if (allMarkets[i] == mToken) return true;
        }
        return false;
    }
}
