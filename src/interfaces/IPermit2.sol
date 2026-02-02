// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IPermit2
/// @notice Interface for Uniswap Permit2 contract
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}
