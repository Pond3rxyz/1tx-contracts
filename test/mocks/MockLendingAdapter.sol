// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ILendingAdapter} from "../../src/interfaces/ILendingAdapter.sol";

/// @title MockLendingAdapter
/// @notice Mock lending adapter for registry unit tests
contract MockLendingAdapter is ILendingAdapter {
    string public adapterName;
    uint256 public adapterChainId;

    struct MarketInfo {
        bool active;
        address yieldToken;
        Currency currency;
    }

    mapping(bytes32 => MarketInfo) public markets;

    constructor(string memory _name, uint256 _chainId) {
        adapterName = _name;
        adapterChainId = _chainId;
    }

    function addMockMarket(bytes32 marketId, address yieldToken, Currency currency) external {
        markets[marketId] = MarketInfo({active: true, yieldToken: yieldToken, currency: currency});
    }

    function removeMockMarket(bytes32 marketId) external {
        delete markets[marketId];
    }

    function setChainId(uint256 _chainId) external {
        adapterChainId = _chainId;
    }

    // ============ ILendingAdapter Implementation ============

    function getAdapterMetadata() external view override returns (AdapterMetadata memory) {
        return AdapterMetadata({name: adapterName, chainId: adapterChainId});
    }

    function hasMarket(bytes32 marketId) external view override returns (bool) {
        return markets[marketId].active;
    }

    function deposit(bytes32, uint256, address) external override {}

    function withdraw(bytes32, uint256, address) external pure override returns (uint256) {
        return 0;
    }

    function getYieldToken(bytes32 marketId) external view override returns (address) {
        return markets[marketId].yieldToken;
    }

    function getMarketCurrency(bytes32 marketId) external view override returns (Currency) {
        return markets[marketId].currency;
    }

    function convertToUnderlying(bytes32, uint256 yieldTokenAmount) external pure override returns (uint256) {
        return yieldTokenAmount;
    }

    function requiresAllow() external pure override returns (bool) {
        return false;
    }
}
