// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "../../interfaces/ILendingAdapter.sol";

/// @title AdapterBase
/// @notice Abstract base contract for lending adapters with shared functionality
/// @dev Provides common errors, validation modifiers, and base structure for all adapters
abstract contract AdapterBase is ILendingAdapter, Ownable {
    using CurrencyLibrary for Currency;

    /// @notice Thrown when the market is not active
    error MarketNotActive();

    /// @notice Thrown when the amount is zero
    error AmountMustBeGreaterThanZero();

    /// @notice Thrown when the recipient address is zero
    error InvalidRecipient();

    /// @notice Thrown when trying to register a market with native currency
    error NativeCurrencyNotSupported();

    /// @notice Thrown when trying to register an already registered market
    error MarketAlreadyRegistered();

    /// @notice Thrown when caller is not authorized to perform withdrawals
    error UnauthorizedCaller();

    /// @notice Thrown when trying to add the zero address as an authorized caller
    error InvalidAuthorizedCaller();

    /// @notice Thrown when the yield token's underlying asset doesn't match the expected currency
    error AssetMismatch();

    /// @notice Maps addresses that are authorized to call withdraw functions
    mapping(address => bool) public authorizedCallers;

    /// @notice Emitted when an authorized caller is added
    event AuthorizedCallerAdded(address indexed caller);

    /// @notice Emitted when an authorized caller is removed
    event AuthorizedCallerRemoved(address indexed caller);

    /// @notice Constructor that passes the initial owner to Ownable
    /// @param initialOwner The initial owner of the adapter
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Validates deposit and withdraw parameters
    /// @param amount The amount to validate (must be > 0)
    /// @param recipient The recipient address to validate (must be non-zero)
    modifier validDepositWithdrawParams(uint256 amount, address recipient) {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (recipient == address(0)) revert InvalidRecipient();
        _;
    }

    /// @notice Validates that a currency is not native (address(0))
    /// @param currency The currency to validate
    modifier validCurrency(Currency currency) {
        if (currency.isAddressZero()) revert NativeCurrencyNotSupported();
        _;
    }

    /// @notice Ensures only authorized callers can execute the function
    modifier onlyAuthorizedCaller() {
        if (!authorizedCallers[msg.sender]) revert UnauthorizedCaller();
        _;
    }

    /// @notice Adds an address as an authorized caller
    /// @param caller The address to authorize
    function addAuthorizedCaller(address caller) external onlyOwner {
        if (caller == address(0)) revert InvalidAuthorizedCaller();
        authorizedCallers[caller] = true;
        emit AuthorizedCallerAdded(caller);
    }

    /// @notice Removes an address from authorized callers
    /// @param caller The address to remove authorization from
    function removeAuthorizedCaller(address caller) external onlyOwner {
        authorizedCallers[caller] = false;
        emit AuthorizedCallerRemoved(caller);
    }

    /// @inheritdoc ILendingAdapter
    function requiresAllow() external pure virtual returns (bool) {
        return false;
    }
}
