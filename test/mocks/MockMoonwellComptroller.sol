// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMoonwellComptroller} from "../../src/interfaces/IMoonwellComptroller.sol";

/// @title MockMoonwellComptroller
/// @notice Mock Moonwell Comptroller for testing
contract MockMoonwellComptroller is IMoonwellComptroller {
    address[] private _allMarkets;
    mapping(address account => address[] assets) private _accountAssets;
    mapping(address account => mapping(address mToken => bool)) private _membership;

    function addMarket(address mToken) external {
        _allMarkets.push(mToken);
    }

    function getAllMarkets() external view override returns (address[] memory) {
        return _allMarkets;
    }

    function checkMembership(address account, address mToken) external view override returns (bool) {
        return _membership[account][mToken];
    }

    function enterMarkets(address[] memory mTokens) external override returns (uint256[] memory) {
        uint256[] memory results = new uint256[](mTokens.length);
        for (uint256 i = 0; i < mTokens.length; i++) {
            _membership[msg.sender][mTokens[i]] = true;
            _accountAssets[msg.sender].push(mTokens[i]);
            results[i] = 0; // Success
        }
        return results;
    }

    function exitMarket(address mTokenAddress) external override returns (uint256) {
        _membership[msg.sender][mTokenAddress] = false;
        return 0; // Success
    }

    function getHypotheticalAccountLiquidity(address, address, uint256, uint256)
        external
        pure
        override
        returns (uint256, uint256, uint256)
    {
        return (0, type(uint256).max, 0); // No error, max liquidity, no shortfall
    }

    function getAssetsIn(address account) external view override returns (address[] memory) {
        return _accountAssets[account];
    }
}
