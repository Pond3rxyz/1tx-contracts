// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterBase} from "./base/AdapterBase.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";

/// @title EulerAdapter
/// @notice Adapter for managing Euler Earn Vaults (ERC-4626 compliant)
/// @dev Implements the ILendingAdapter interface for Euler Earn Vaults
contract EulerAdapter is AdapterBase {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    /// @notice Thrown when the vault address is zero
    error InvalidVaultAddress();

    /// @notice Configuration for a single Euler Earn vault
    struct VaultConfig {
        Currency currency;
        address vault; // ERC-4626 vault address (also the yield token)
        bool active;
    }

    /// @notice Maps marketId to vault configuration
    mapping(bytes32 marketId => VaultConfig) public vaults;

    /// @notice Emitted when a new vault is registered
    event VaultRegistered(bytes32 indexed marketId, Currency currency, address vault);

    /// @notice Emitted when a vault is deactivated
    event VaultDeactivated(bytes32 indexed marketId);

    /// @notice Emitted when a deposit is made to Euler Earn Vault
    event DepositedToEuler(bytes32 indexed marketId, uint256 assets, uint256 shares, address onBehalfOf);

    /// @notice Emitted when a withdrawal is made from Euler Earn Vault
    event WithdrawnFromEuler(bytes32 indexed marketId, uint256 assets, uint256 shares, address to);

    /// @notice Constructor
    /// @param initialOwner The initial owner of the adapter (can register vaults)
    constructor(address initialOwner) AdapterBase(initialOwner) {}

    /// @notice Registers a new Euler Earn Vault in this adapter
    /// @dev Only the adapter owner can register vaults
    /// @dev Market ID is derived from vault address to support multiple vaults per currency
    /// @dev Uses simple encoding to avoid double-hashing (vault is also in executionAddress)
    /// @param currency The underlying currency for this vault
    /// @param vault The address of the ERC-4626 vault contract
    function registerVault(Currency currency, address vault) external onlyOwner validCurrency(currency) {
        if (vault == address(0)) revert InvalidVaultAddress();

        // Verify that the vault's asset matches the currency
        address vaultAsset = IERC4626(vault).asset();
        if (vaultAsset != Currency.unwrap(currency)) revert AssetMismatch();

        // Generate market ID from vault address to allow multiple vaults per currency
        // This enables different strategies/vaults for the same asset
        // Use simple cast to avoid double-hashing (vault address will be hashed with this in instrumentId)
        bytes32 marketId = bytes32(uint256(uint160(vault)));
        if (vaults[marketId].active) revert MarketAlreadyRegistered();

        vaults[marketId] = VaultConfig({currency: currency, vault: vault, active: true});

        emit VaultRegistered(marketId, currency, vault);
    }

    /// @notice Deactivates a vault
    /// @dev Only the adapter owner can deactivate vaults
    /// @param marketId The market identifier to deactivate
    function deactivateMarket(bytes32 marketId) external onlyOwner {
        if (!vaults[marketId].active) revert MarketNotActive();
        vaults[marketId].active = false;
        emit VaultDeactivated(marketId);
    }

    /// @notice Returns the metadata for this lending adapter
    /// @return metadata The adapter metadata containing name and chainId
    function getAdapterMetadata() external view override returns (AdapterMetadata memory metadata) {
        return AdapterMetadata({name: "Euler Earn", chainId: block.chainid});
    }

    /// @notice Checks if a vault is registered and active
    /// @param marketId The market identifier
    /// @return True if the vault is registered and active
    function hasMarket(bytes32 marketId) external view override returns (bool) {
        return vaults[marketId].active;
    }

    /// @notice Deposits tokens into Euler Earn Vault (ERC-4626)
    /// @param marketId The market identifier
    /// @param amount The amount of assets to deposit
    /// @param onBehalfOf The address that will receive the vault shares
    function deposit(bytes32 marketId, uint256 amount, address onBehalfOf)
        external
        override
        validDepositWithdrawParams(amount, onBehalfOf)
    {
        VaultConfig memory config = vaults[marketId];
        if (!config.active) revert MarketNotActive();

        address tokenAddress = Currency.unwrap(config.currency);
        IERC4626 vault = IERC4626(config.vault);

        // Transfer tokens from caller to this adapter
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);

        // Approve vault to spend tokens
        IERC20(tokenAddress).forceApprove(config.vault, amount);

        // Deposit assets to vault and mint shares to onBehalfOf
        uint256 shares = vault.deposit(amount, onBehalfOf);

        emit DepositedToEuler(marketId, amount, shares, onBehalfOf);
    }

    /// @notice Withdraws tokens from Euler Earn Vault (ERC-4626)
    /// @param marketId The market identifier
    /// @param amount The amount of vault shares to redeem
    /// @param to The address that will receive the withdrawn tokens
    /// @dev The caller (msg.sender) must have transferred vault shares to this adapter
    function withdraw(bytes32 marketId, uint256 amount, address to)
        external
        override
        onlyAuthorizedCaller
        validDepositWithdrawParams(amount, to)
        returns (uint256 assetsWithdrawn)
    {
        VaultConfig memory config = vaults[marketId];
        if (!config.active) revert MarketNotActive();

        IERC4626 vault = IERC4626(config.vault);

        // amount represents vault SHARES to redeem, not assets
        // Vault shares have already been transferred to this adapter by the hook

        // Redeem the shares for assets and send to recipient
        // Shares are redeemed from this adapter's balance (owner parameter)
        uint256 assetsReceived = vault.redeem(amount, to, address(this));

        emit WithdrawnFromEuler(marketId, assetsReceived, amount, to);

        return assetsReceived;
    }

    /// @notice Returns the yield-bearing token address for a given market
    /// @param marketId The market identifier
    /// @return The address of the ERC-4626 vault (which is the yield token)
    function getYieldToken(bytes32 marketId) external view override returns (address) {
        VaultConfig memory config = vaults[marketId];
        if (!config.active) revert MarketNotActive();
        return config.vault;
    }

    /// @notice Returns the underlying currency for a given market
    /// @param marketId The market identifier
    /// @return The underlying currency of the vault
    function getMarketCurrency(bytes32 marketId) external view override returns (Currency) {
        VaultConfig memory config = vaults[marketId];
        if (!config.active) revert MarketNotActive();
        return config.currency;
    }

    /// @notice Converts vault shares to underlying asset value via ERC-4626
    /// @param marketId The market identifier
    /// @param yieldTokenAmount The amount of vault shares
    /// @return The equivalent amount of underlying assets
    function convertToUnderlying(bytes32 marketId, uint256 yieldTokenAmount) external view override returns (uint256) {
        VaultConfig memory config = vaults[marketId];
        if (!config.active) revert MarketNotActive();
        return IERC4626(config.vault).convertToAssets(yieldTokenAmount);
    }
}
