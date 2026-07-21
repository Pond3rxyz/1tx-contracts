// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterBaseUpgradeableV1} from "./AdapterBaseUpgradeableV1.sol";
import {IAavePool} from "../../../../src/interfaces/IAavePool.sol";

/// @title AaveAdapterV1
/// @notice FROZEN storage-layout snapshot of {AaveAdapter} at the first upgradeable release.
///         Reference for `Upgrades.validateUpgrade`. Never edit.
contract AaveAdapterV1 is AdapterBaseUpgradeableV1 {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    error InvalidPoolAddress();
    error ReserveNotFound();

    struct MarketConfig {
        Currency currency;
        address yieldToken;
        bool active;
    }

    IAavePool public AAVE_POOL;

    mapping(bytes32 marketId => MarketConfig) public markets;

    event MarketRegistered(bytes32 indexed marketId, Currency currency, address yieldToken);
    event MarketDeactivated(bytes32 indexed marketId);
    event DepositedToAave(bytes32 indexed marketId, uint256 amount, address onBehalfOf);
    event WithdrawnFromAave(bytes32 indexed marketId, uint256 amount, address to);

    function initialize(address _aavePool, address initialOwner) external initializer {
        if (_aavePool == address(0)) revert InvalidPoolAddress();
        __AdapterBase_init(initialOwner);
        AAVE_POOL = IAavePool(_aavePool);
    }

    function registerMarket(Currency currency) external onlyOwner validCurrency(currency) {
        address tokenAddress = Currency.unwrap(currency);
        IAavePool.ReserveData memory reserveData = AAVE_POOL.getReserveData(tokenAddress);
        if (reserveData.aTokenAddress == address(0)) revert ReserveNotFound();

        bytes32 marketId = keccak256(abi.encode(currency));
        if (markets[marketId].active) revert MarketAlreadyRegistered();

        markets[marketId] = MarketConfig({currency: currency, yieldToken: reserveData.aTokenAddress, active: true});

        emit MarketRegistered(marketId, currency, reserveData.aTokenAddress);
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
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(tokenAddress).forceApprove(address(AAVE_POOL), amount);
        AAVE_POOL.supply(tokenAddress, amount, onBehalfOf, 0);

        emit DepositedToAave(marketId, amount, onBehalfOf);
    }

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
        withdrawnAmount = AAVE_POOL.withdraw(tokenAddress, amount, address(this));
        IERC20(tokenAddress).safeTransfer(to, withdrawnAmount);

        emit WithdrawnFromAave(marketId, withdrawnAmount, to);
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
        return AdapterMetadata({name: "Aave V3", chainId: block.chainid});
    }

    function convertToUnderlying(bytes32, uint256 yieldTokenAmount) external pure returns (uint256) {
        return yieldTokenAmount;
    }

    uint256[50] private __gap;
}
