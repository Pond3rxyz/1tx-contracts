// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IUniversalRouter
/// @notice Interface for Uniswap Universal Router
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
