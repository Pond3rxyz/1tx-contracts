// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterBase} from "./base/AdapterBase.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";

/// @title AaveAdapter
/// @notice Adapter for managing multiple Aave v3 markets
/// @dev Implements the ILendingAdapter interface for Aave v3 protocol
contract AaveAdapter is AdapterBase {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    /// @notice Thrown when the pool address is zero
    error InvalidPoolAddress();

    /// @notice Thrown when the reserve is not found in Aave
    error ReserveNotFound();

    /// @notice Configuration for a single Aave market
    struct MarketConfig {
        Currency currency;
        address yieldToken; // aToken address
        bool active;
    }

    /// @notice The Aave v3 Pool contract
    IAavePool public immutable AAVE_POOL;

    /// @notice Maps marketId to market configuration
    mapping(bytes32 marketId => MarketConfig) public markets;

    /// @notice Emitted when a new market is registered
    event MarketRegistered(bytes32 indexed marketId, Currency currency, address yieldToken);

    /// @notice Emitted when a market is deactivated
    event MarketDeactivated(bytes32 indexed marketId);

    /// @notice Emitted when a deposit is made to Aave
    event DepositedToAave(bytes32 indexed marketId, uint256 amount, address onBehalfOf);

    /// @notice Emitted when a withdrawal is made from Aave
    event WithdrawnFromAave(bytes32 indexed marketId, uint256 amount, address to);

    /// @notice Constructor
    /// @param _aavePool The address of the Aave v3 Pool contract
    /// @param initialOwner The initial owner of the adapter (can register markets)
    constructor(address _aavePool, address initialOwner) AdapterBase(initialOwner) {
        if (_aavePool == address(0)) revert InvalidPoolAddress();
        AAVE_POOL = IAavePool(_aavePool);
    }

    /// @notice Registers a new market in this adapter
    /// @dev Only the adapter owner can register markets
    /// @param currency The underlying currency for this market
    function registerMarket(Currency currency) external onlyOwner validCurrency(currency) {
        address tokenAddress = Currency.unwrap(currency);
        IAavePool.ReserveData memory reserveData = AAVE_POOL.getReserveData(tokenAddress);
        if (reserveData.aTokenAddress == address(0)) revert ReserveNotFound();

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 marketId = keccak256(abi.encode(currency));
        if (markets[marketId].active) revert MarketAlreadyRegistered();

        markets[marketId] = MarketConfig({currency: currency, yieldToken: reserveData.aTokenAddress, active: true});

        emit MarketRegistered(marketId, currency, reserveData.aTokenAddress);
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
        return AdapterMetadata({name: "Aave V3", chainId: block.chainid});
    }

    /// @notice Checks if a market is registered and active
    /// @param marketId The market identifier
    /// @return True if the market is registered and active
    function hasMarket(bytes32 marketId) external view override returns (bool) {
        return markets[marketId].active;
    }

    /// @notice Deposits tokens into Aave v3
    /// @param marketId The market identifier
    /// @param amount The amount to deposit
    /// @param onBehalfOf The address that will receive the aTokens
    function deposit(bytes32 marketId, uint256 amount, address onBehalfOf)
        external
        override
        validDepositWithdrawParams(amount, onBehalfOf)
    {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();

        address tokenAddress = Currency.unwrap(config.currency);

        // Transfer tokens from caller to this adapter
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);

        // Approve Aave pool to spend tokens
        IERC20(tokenAddress).forceApprove(address(AAVE_POOL), amount);

        // Supply tokens to Aave on behalf of the specified address
        AAVE_POOL.supply(tokenAddress, amount, onBehalfOf, 0);

        emit DepositedToAave(marketId, amount, onBehalfOf);
    }

    /// @notice Withdraws tokens from Aave v3
    /// @param marketId The market identifier
    /// @param amount The amount of aTokens to redeem (1:1 with underlying)
    /// @param to The address that will receive the withdrawn tokens
    /// @dev The hook must transfer aTokens to this adapter before calling withdraw.
    ///      Aave's withdraw() burns aTokens from the caller (this adapter).
    function withdraw(bytes32 marketId, uint256 amount, address to)
        external
        override
        onlyAuthorizedCaller
        validDepositWithdrawParams(amount, to)
        returns (uint256 withdrawnAmount)
    {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();

        address tokenAddress = Currency.unwrap(config.currency);

        // Withdraw tokens from Aave - sends underlying tokens to this adapter
        withdrawnAmount = AAVE_POOL.withdraw(tokenAddress, amount, address(this));

        // Transfer the withdrawn tokens to the specified recipient
        IERC20(tokenAddress).safeTransfer(to, withdrawnAmount);

        emit WithdrawnFromAave(marketId, withdrawnAmount, to);
    }

    /// @notice Returns the yield-bearing token address for a given market
    /// @param marketId The market identifier
    /// @return The address of the corresponding aToken
    function getYieldToken(bytes32 marketId) external view override returns (address) {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();
        return config.yieldToken;
    }

    /// @notice Returns the underlying currency for a given market
    /// @param marketId The market identifier
    /// @return The underlying currency of the market
    function getMarketCurrency(bytes32 marketId) external view override returns (Currency) {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();
        return config.currency;
    }
}
