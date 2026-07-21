// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "../../interfaces/ILendingAdapter.sol";

/// @title AdapterBaseUpgradeable
/// @notice Abstract UUPS-upgradeable base contract for lending adapters with shared functionality
/// @dev Upgradeable counterpart of {AdapterBase}. Each adapter sits behind its own ERC1967Proxy so
///      its address is permanent: new logic ships as an implementation swap via `upgradeToAndCall`,
///      never requiring instruments to be unregistered and re-registered in the InstrumentRegistry.
///      Mirrors the UUPS pattern already used by InstrumentRegistry and SwapDepositRouter.
abstract contract AdapterBaseUpgradeable is ILendingAdapter, Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using CurrencyLibrary for Currency;

    /// @notice Metadata describing this adapter
    /// @dev Kept for backward compatibility with the deployed InstrumentRegistry, which reads it
    ///      during registerInstrument and validates `chainId == block.chainid`.
    struct AdapterMetadata {
        string name;
        uint256 chainId;
    }

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
    /// @dev Slot 0 of the adapter's own storage. Kept first to preserve semantics across upgrades.
    mapping(address => bool) public authorizedCallers;

    /// @notice Emitted when an authorized caller is updated
    event AuthorizedCallerUpdated(address indexed caller, bool allowed);

    /// @notice Disables initializers on the implementation so it can only be used behind a proxy.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the shared adapter base (owner + UUPS wiring)
    /// @dev Concrete adapters call this from their own `initialize(...)`.
    /// @param initialOwner The initial owner of the adapter
    function __AdapterBase_init(address initialOwner) internal onlyInitializing {
        __Ownable_init(initialOwner);
    }

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

    /// @notice Sets whether an address is an authorized caller
    /// @param caller The address to update
    /// @param allowed Whether the caller is authorized
    function setAuthorizedCaller(address caller, bool allowed) external onlyOwner {
        if (caller == address(0)) revert InvalidAuthorizedCaller();
        authorizedCallers[caller] = allowed;
        emit AuthorizedCallerUpdated(caller, allowed);
    }

    /// @notice Whether this adapter requires callers to be explicitly allowed before withdrawing
    /// @dev Backward-compatibility shim for the deployed registry/router ABI. ERC-4626 style
    ///      adapters do not require an allow step, so this defaults to false.
    function requiresAllow() external pure virtual returns (bool) {
        return false;
    }

    /// @notice Restricts upgrades to the adapter owner.
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Reserved storage to allow future base-level fields without shifting derived layout.
    uint256[49] private __gap;
}
