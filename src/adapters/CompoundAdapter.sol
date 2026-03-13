// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterBase} from "./base/AdapterBase.sol";
import {ICompoundV3} from "../interfaces/ICompoundV3.sol";

/// @title CompoundAdapter
/// @notice Adapter for managing Compound V3 (Comet) markets
/// @dev Implements the ILendingAdapter interface for Compound V3 protocol
/// @dev Supports multiple Comet contracts (one per base asset)
contract CompoundAdapter is AdapterBase {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    /// @notice Thrown when the yield token address is zero
    error InvalidYieldTokenAddress();

    /// @notice Configuration for a single Compound market
    struct MarketConfig {
        Currency currency;
        address yieldToken; // Comet contract address for this market
        bool active;
    }

    /// @notice Maps marketId to market configuration
    mapping(bytes32 marketId => MarketConfig) public markets;

    /// @notice Emitted when a new market is registered
    event MarketRegistered(bytes32 indexed marketId, Currency currency, address yieldToken);

    /// @notice Emitted when a market is deactivated
    event MarketDeactivated(bytes32 indexed marketId);

    /// @notice Emitted when a deposit is made to Compound
    event DepositedToCompound(bytes32 indexed marketId, uint256 amount, address onBehalfOf);

    /// @notice Emitted when a withdrawal is made from Compound
    event WithdrawnFromCompound(bytes32 indexed marketId, uint256 amount, address to);

    /// @notice Constructor
    /// @param initialOwner The initial owner of the adapter (can register markets)
    constructor(address initialOwner) AdapterBase(initialOwner) {
        // No single Comet - each market will have its own Comet contract
    }

    /// @notice Registers a new market in this adapter
    /// @dev Only the adapter owner can register markets
    /// @param currency The underlying currency for this market
    /// @param yieldToken The cToken address for this market (usually the Comet contract itself)
    function registerMarket(Currency currency, address yieldToken) external onlyOwner validCurrency(currency) {
        if (yieldToken == address(0)) revert InvalidYieldTokenAddress();

        // forge-lint: disable-next-line(asm-keccak256)
        bytes32 marketId = keccak256(abi.encode(currency));
        if (markets[marketId].active) revert MarketAlreadyRegistered();

        markets[marketId] = MarketConfig({currency: currency, yieldToken: yieldToken, active: true});

        emit MarketRegistered(marketId, currency, yieldToken);
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
        return AdapterMetadata({name: "Compound V3", chainId: block.chainid});
    }

    /// @notice Checks if a market is registered and active
    /// @param marketId The market identifier
    /// @return True if the market is registered and active
    function hasMarket(bytes32 marketId) external view override returns (bool) {
        return markets[marketId].active;
    }

    /// @notice Deposits tokens into Compound V3
    /// @param marketId The market identifier
    /// @param amount The amount to deposit
    /// @param onBehalfOf The address that will receive the cTokens
    function deposit(bytes32 marketId, uint256 amount, address onBehalfOf)
        external
        override
        validDepositWithdrawParams(amount, onBehalfOf)
    {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();

        address tokenAddress = Currency.unwrap(config.currency);
        ICompoundV3 comet = ICompoundV3(config.yieldToken);

        // Transfer tokens from caller to this adapter
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);

        // Approve Comet to spend tokens (using forceApprove for USDT-like tokens)
        IERC20(tokenAddress).forceApprove(config.yieldToken, amount);

        // Supply tokens to Compound on behalf of the specified address
        comet.supplyTo(onBehalfOf, tokenAddress, amount);

        emit DepositedToCompound(marketId, amount, onBehalfOf);
    }

    /// @notice Withdraws tokens from Compound V3
    /// @param marketId The market identifier
    /// @param amount The amount of Comet tokens to redeem (Comet tokens are ERC20)
    /// @param to The address that will receive the withdrawn tokens
    /// @dev The hook transfers Comet tokens to this adapter before calling withdraw
    function withdraw(bytes32 marketId, uint256 amount, address to)
        external
        override
        onlyAuthorizedCaller
        validDepositWithdrawParams(amount, to)
        returns (uint256)
    {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();

        address tokenAddress = Currency.unwrap(config.currency);
        ICompoundV3 comet = ICompoundV3(config.yieldToken);

        // Comet tokens have already been transferred to this adapter by the hook.
        // Use balanceOf (not amount) because Comet's interest accrual can cause
        // slight differences. Cap to amount to avoid sweeping unrelated tokens.
        uint256 adapterBalance = comet.balanceOf(address(this));
        uint256 withdrawAmount = adapterBalance < amount ? adapterBalance : amount;

        comet.withdraw(tokenAddress, withdrawAmount);

        // Transfer the withdrawn underlying tokens to the recipient
        uint256 actualAmount = IERC20(tokenAddress).balanceOf(address(this));
        IERC20(tokenAddress).safeTransfer(to, actualAmount);

        emit WithdrawnFromCompound(marketId, actualAmount, to);

        return actualAmount;
    }

    /// @notice Returns the yield-bearing token address for a given market
    /// @param marketId The market identifier
    /// @return The address of the corresponding cToken
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

    /// @notice Converts Comet balance to underlying value (1:1 for Compound V3)
    /// @dev Comet's balanceOf already returns the underlying value including accrued interest
    /// @param yieldTokenAmount The Comet token balance
    /// @return The equivalent amount of underlying assets
    function convertToUnderlying(bytes32, uint256 yieldTokenAmount) external pure override returns (uint256) {
        return yieldTokenAmount;
    }

    /// @notice Compound V3 comet tokens require allow() instead of approve()
    /// @return True since Compound V3 uses permission-based transfers
    function requiresAllow() external pure override returns (bool) {
        return true;
    }
}
