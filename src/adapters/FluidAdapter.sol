// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterBase} from "./base/AdapterBase.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";

/// @title FluidAdapter
/// @notice Adapter for managing Fluid fTokens (ERC-4626 compliant)
/// @dev Implements the ILendingAdapter interface for Fluid Lending Protocol
contract FluidAdapter is AdapterBase {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    /// @notice Thrown when the fToken address is zero
    error InvalidFTokenAddress();

    /// @notice Configuration for a single Fluid fToken
    struct FTokenConfig {
        Currency currency;
        address fToken; // ERC-4626 fToken address (also the yield token)
        bool active;
    }

    /// @notice Maps marketId to fToken configuration
    mapping(bytes32 marketId => FTokenConfig) public fTokens;

    /// @notice Emitted when a new fToken is registered
    event FTokenRegistered(bytes32 indexed marketId, Currency currency, address fToken);

    /// @notice Emitted when a fToken is deactivated
    event FTokenDeactivated(bytes32 indexed marketId);

    /// @notice Emitted when a deposit is made to Fluid fToken
    event DepositedToFluid(bytes32 indexed marketId, uint256 assets, uint256 shares, address onBehalfOf);

    /// @notice Emitted when a withdrawal is made from Fluid fToken
    event WithdrawnFromFluid(bytes32 indexed marketId, uint256 assets, uint256 shares, address to);

    /// @notice Constructor
    /// @param initialOwner The initial owner of the adapter (can register fTokens)
    constructor(address initialOwner) AdapterBase(initialOwner) {}

    /// @notice Registers a new Fluid fToken in this adapter
    /// @dev Only the adapter owner can register fTokens
    /// @dev Market ID is derived from fToken address to support multiple fTokens per currency
    /// @dev Uses simple encoding to avoid double-hashing (fToken is also in executionAddress)
    /// @param currency The underlying currency for this fToken
    /// @param fToken The address of the ERC-4626 fToken contract
    function registerFToken(Currency currency, address fToken) external onlyOwner validCurrency(currency) {
        if (fToken == address(0)) revert InvalidFTokenAddress();

        // Verify that the fToken's asset matches the currency
        address fTokenAsset = IERC4626(fToken).asset();
        if (fTokenAsset != Currency.unwrap(currency)) revert AssetMismatch();

        // Generate market ID from fToken address to allow multiple fTokens per currency
        // This enables different strategies/vaults for the same asset (e.g., multiple USDC fTokens)
        // Use simple cast to avoid double-hashing (fToken address will be hashed with this in instrumentId)
        bytes32 marketId = bytes32(uint256(uint160(fToken)));
        if (fTokens[marketId].active) revert MarketAlreadyRegistered();

        fTokens[marketId] = FTokenConfig({currency: currency, fToken: fToken, active: true});

        emit FTokenRegistered(marketId, currency, fToken);
    }

    /// @notice Deactivates a fToken
    /// @dev Only the adapter owner can deactivate fTokens
    /// @param marketId The market identifier to deactivate
    function deactivateMarket(bytes32 marketId) external onlyOwner {
        if (!fTokens[marketId].active) revert MarketNotActive();
        fTokens[marketId].active = false;
        emit FTokenDeactivated(marketId);
    }

    /// @notice Returns the metadata for this lending adapter
    /// @return metadata The adapter metadata containing name and chainId
    function getAdapterMetadata() external view override returns (AdapterMetadata memory metadata) {
        return AdapterMetadata({name: "Fluid Lending", chainId: block.chainid});
    }

    /// @notice Checks if a fToken is registered and active
    /// @param marketId The market identifier
    /// @return True if the fToken is registered and active
    function hasMarket(bytes32 marketId) external view override returns (bool) {
        return fTokens[marketId].active;
    }

    /// @notice Deposits tokens into Fluid fToken (ERC-4626)
    /// @param marketId The market identifier
    /// @param amount The amount of assets to deposit
    /// @param onBehalfOf The address that will receive the fToken shares
    function deposit(bytes32 marketId, uint256 amount, address onBehalfOf)
        external
        override
        validDepositWithdrawParams(amount, onBehalfOf)
    {
        FTokenConfig memory config = fTokens[marketId];
        if (!config.active) revert MarketNotActive();

        address tokenAddress = Currency.unwrap(config.currency);
        IERC4626 fToken = IERC4626(config.fToken);

        // Transfer tokens from caller to this adapter
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);

        // Approve fToken to spend tokens
        IERC20(tokenAddress).forceApprove(config.fToken, amount);

        // Deposit assets to fToken and mint shares to onBehalfOf
        uint256 shares = fToken.deposit(amount, onBehalfOf);

        emit DepositedToFluid(marketId, amount, shares, onBehalfOf);
    }

    /// @notice Withdraws tokens from Fluid fToken (ERC-4626)
    /// @param marketId The market identifier
    /// @param amount The amount of fToken shares to redeem
    /// @param to The address that will receive the withdrawn tokens
    /// @dev The caller (msg.sender) must have transferred fToken shares to this adapter
    function withdraw(bytes32 marketId, uint256 amount, address to)
        external
        override
        onlyAuthorizedCaller
        validDepositWithdrawParams(amount, to)
        returns (uint256 assetsWithdrawn)
    {
        FTokenConfig memory config = fTokens[marketId];
        if (!config.active) revert MarketNotActive();

        IERC4626 fToken = IERC4626(config.fToken);

        // amount represents fToken SHARES to redeem, not assets
        // fToken shares have already been transferred to this adapter by the hook

        // Redeem the shares for assets and send to recipient
        // Shares are redeemed from this adapter's balance (owner parameter)
        uint256 assetsReceived = fToken.redeem(amount, to, address(this));

        emit WithdrawnFromFluid(marketId, assetsReceived, amount, to);

        return assetsReceived;
    }

    /// @notice Returns the yield-bearing token address for a given market
    /// @param marketId The market identifier
    /// @return The address of the ERC-4626 fToken (which is the yield token)
    function getYieldToken(bytes32 marketId) external view override returns (address) {
        FTokenConfig memory config = fTokens[marketId];
        if (!config.active) revert MarketNotActive();
        return config.fToken;
    }

    /// @notice Returns the underlying currency for a given market
    /// @param marketId The market identifier
    /// @return The underlying currency of the fToken
    function getMarketCurrency(bytes32 marketId) external view override returns (Currency) {
        FTokenConfig memory config = fTokens[marketId];
        if (!config.active) revert MarketNotActive();
        return config.currency;
    }
}
