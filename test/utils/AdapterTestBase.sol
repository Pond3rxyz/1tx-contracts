// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

/// @title AdapterTestBase
/// @notice Base contract for adapter unit tests with common setup and utilities
abstract contract AdapterTestBase is Test {
    using CurrencyLibrary for Currency;

    // Common test addresses
    address public owner;
    address public user;
    address public authorizedCaller;
    address public recipient;

    // Common mock tokens
    MockERC20 public usdc;
    MockERC20 public usdt;

    // Common currencies
    Currency public usdcCurrency;
    Currency public usdtCurrency;
    Currency public nativeCurrency;

    // Common amounts
    uint256 public constant INITIAL_BALANCE = 1_000_000e6; // 1M tokens
    uint256 public constant DEPOSIT_AMOUNT = 1000e6; // 1k tokens

    function setUp() public virtual {
        // Setup addresses
        owner = makeAddr("owner");
        user = makeAddr("user");
        authorizedCaller = makeAddr("authorizedCaller");
        recipient = makeAddr("recipient");

        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        // Setup currencies
        usdcCurrency = Currency.wrap(address(usdc));
        usdtCurrency = Currency.wrap(address(usdt));
        nativeCurrency = CurrencyLibrary.ADDRESS_ZERO;

        // Mint initial balances
        usdc.mint(user, INITIAL_BALANCE);
        usdt.mint(user, INITIAL_BALANCE);
    }

    /// @notice Helper to compute market ID from currency (Aave/Compound pattern)
    function _computeMarketId(Currency currency) internal pure returns (bytes32) {
        return keccak256(abi.encode(currency));
    }

    /// @notice Helper to compute market ID from vault/fToken address (Morpho/Fluid pattern)
    function _computeVaultMarketId(address vault) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(vault)));
    }

    /// @notice Helper to approve tokens from user to spender
    function _approveTokens(address token, address from, address spender, uint256 amount) internal {
        vm.prank(from);
        MockERC20(token).approve(spender, amount);
    }

    /// @notice Helper to mint tokens to an address
    function _mintTokens(address token, address to, uint256 amount) internal {
        MockERC20(token).mint(to, amount);
    }
}
