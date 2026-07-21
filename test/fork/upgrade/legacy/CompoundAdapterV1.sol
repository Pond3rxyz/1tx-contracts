// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterBaseUpgradeableV1} from "./AdapterBaseUpgradeableV1.sol";
import {ICompoundV3} from "../../../../src/interfaces/ICompoundV3.sol";

/// @title CompoundAdapterV1
/// @notice FROZEN storage-layout snapshot of {CompoundAdapter} at the first upgradeable release.
///         Reference for `Upgrades.validateUpgrade`. Never edit.
contract CompoundAdapterV1 is AdapterBaseUpgradeableV1 {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    error InvalidYieldTokenAddress();

    struct MarketConfig {
        Currency currency;
        address yieldToken;
        bool active;
    }

    mapping(bytes32 marketId => MarketConfig) public markets;

    event MarketRegistered(bytes32 indexed marketId, Currency currency, address yieldToken);
    event MarketDeactivated(bytes32 indexed marketId);
    event DepositedToCompound(bytes32 indexed marketId, uint256 amount, address onBehalfOf);
    event WithdrawnFromCompound(bytes32 indexed marketId, uint256 amount, address to);

    function initialize(address initialOwner) external initializer {
        __AdapterBase_init(initialOwner);
    }

    function registerMarket(Currency currency, address yieldToken) external onlyOwner validCurrency(currency) {
        if (yieldToken == address(0)) revert InvalidYieldTokenAddress();

        bytes32 marketId = keccak256(abi.encode(currency));
        if (markets[marketId].active) revert MarketAlreadyRegistered();

        markets[marketId] = MarketConfig({currency: currency, yieldToken: yieldToken, active: true});

        emit MarketRegistered(marketId, currency, yieldToken);
    }

    function deactivateMarket(bytes32 marketId) external onlyOwner {
        if (!markets[marketId].active) revert MarketNotActive();
        markets[marketId].active = false;
        emit MarketDeactivated(marketId);
    }

    function hasMarket(bytes32 marketId) external view override returns (bool) {
        return markets[marketId].active;
    }

    function deposit(bytes32 marketId, uint256 amount, address onBehalfOf)
        external
        override
        validDepositWithdrawParams(amount, onBehalfOf)
    {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();

        address tokenAddress = Currency.unwrap(config.currency);
        ICompoundV3 comet = ICompoundV3(config.yieldToken);

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(tokenAddress).forceApprove(config.yieldToken, amount);
        comet.supplyTo(onBehalfOf, tokenAddress, amount);

        emit DepositedToCompound(marketId, amount, onBehalfOf);
    }

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

        uint256 adapterBalance = comet.balanceOf(address(this));
        uint256 withdrawAmount = adapterBalance < amount ? adapterBalance : amount;

        comet.withdraw(tokenAddress, withdrawAmount);

        uint256 actualAmount = IERC20(tokenAddress).balanceOf(address(this));
        IERC20(tokenAddress).safeTransfer(to, actualAmount);

        emit WithdrawnFromCompound(marketId, actualAmount, to);

        return actualAmount;
    }

    function getYieldToken(bytes32 marketId) external view override returns (address) {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();
        return config.yieldToken;
    }

    function getMarketCurrency(bytes32 marketId) external view override returns (Currency) {
        MarketConfig memory config = markets[marketId];
        if (!config.active) revert MarketNotActive();
        return config.currency;
    }

    function getAdapterMetadata() external view returns (AdapterMetadata memory metadata) {
        return AdapterMetadata({name: "Compound V3", chainId: block.chainid});
    }

    function convertToUnderlying(bytes32, uint256 yieldTokenAmount) external pure returns (uint256) {
        return yieldTokenAmount;
    }

    function requiresAllow() external pure override returns (bool) {
        return true;
    }

    uint256[50] private __gap;
}
