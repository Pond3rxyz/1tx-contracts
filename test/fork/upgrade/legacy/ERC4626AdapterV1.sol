// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterBaseUpgradeableV1} from "./AdapterBaseUpgradeableV1.sol";
import {IERC4626} from "../../../../src/interfaces/IERC4626.sol";

/// @title ERC4626AdapterV1
/// @notice FROZEN storage-layout snapshot of {ERC4626Adapter} (and its Morpho/Euler/Fluid
///         subclasses, which add no storage) at the first upgradeable release. Reference for
///         `Upgrades.validateUpgrade`. Never edit.
contract ERC4626AdapterV1 is AdapterBaseUpgradeableV1 {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    error InvalidVaultAddress();

    struct MarketConfig {
        Currency currency;
        address vault;
        bool active;
    }

    mapping(bytes32 marketId => MarketConfig) internal markets;

    event MarketRegistered(bytes32 indexed marketId, Currency currency, address vault);
    event MarketDeactivated(bytes32 indexed marketId);
    event Deposited(bytes32 indexed marketId, uint256 assets, uint256 shares, address onBehalfOf);
    event Withdrawn(bytes32 indexed marketId, uint256 assets, uint256 shares, address to);

    function initialize(address initialOwner) external initializer {
        __AdapterBase_init(initialOwner);
    }

    function registerMarket(Currency currency, address vault) public onlyOwner validCurrency(currency) {
        if (vault == address(0)) revert InvalidVaultAddress();
        if (IERC4626(vault).asset() != Currency.unwrap(currency)) revert AssetMismatch();

        bytes32 marketId = bytes32(uint256(uint160(vault)));
        if (markets[marketId].active) revert MarketAlreadyRegistered();

        markets[marketId] = MarketConfig({currency: currency, vault: vault, active: true});

        emit MarketRegistered(marketId, currency, vault);
    }

    function deactivateMarket(bytes32 marketId) external onlyOwner {
        MarketConfig storage config = markets[marketId];
        if (!config.active) revert MarketNotActive();
        config.active = false;
        emit MarketDeactivated(marketId);
    }

    function hasMarket(bytes32 marketId) external view override returns (bool) {
        return markets[marketId].active;
    }

    function getAdapterMetadata() external view virtual returns (AdapterMetadata memory metadata) {
        return AdapterMetadata({name: _adapterName(), chainId: block.chainid});
    }

    function convertToUnderlying(bytes32 marketId, uint256 yieldTokenAmount) external view returns (uint256) {
        return IERC4626(_getActiveMarket(marketId).vault).convertToAssets(yieldTokenAmount);
    }

    function _adapterName() internal pure virtual returns (string memory) {
        return "ERC4626 Adapter";
    }

    function deposit(bytes32 marketId, uint256 amount, address onBehalfOf)
        external
        override
        validDepositWithdrawParams(amount, onBehalfOf)
    {
        MarketConfig storage config = _getActiveMarket(marketId);
        address tokenAddress = Currency.unwrap(config.currency);
        IERC4626 vault = IERC4626(config.vault);

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(tokenAddress).forceApprove(config.vault, amount);

        uint256 shares = vault.deposit(amount, onBehalfOf);

        emit Deposited(marketId, amount, shares, onBehalfOf);
    }

    function withdraw(bytes32 marketId, uint256 amount, address to)
        external
        override
        onlyAuthorizedCaller
        validDepositWithdrawParams(amount, to)
        returns (uint256 assetsWithdrawn)
    {
        MarketConfig storage config = _getActiveMarket(marketId);
        assetsWithdrawn = IERC4626(config.vault).redeem(amount, to, address(this));
        emit Withdrawn(marketId, assetsWithdrawn, amount, to);
    }

    function getYieldToken(bytes32 marketId) external view override returns (address) {
        return _getActiveMarket(marketId).vault;
    }

    function getMarketCurrency(bytes32 marketId) external view override returns (Currency) {
        return _getActiveMarket(marketId).currency;
    }

    function _getActiveMarket(bytes32 marketId) internal view returns (MarketConfig storage config) {
        config = markets[marketId];
        if (!config.active) revert MarketNotActive();
    }

    uint256[50] private __gap;
}
