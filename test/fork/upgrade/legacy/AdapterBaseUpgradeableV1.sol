// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {ILendingAdapter} from "../../../../src/interfaces/ILendingAdapter.sol";

/// @title AdapterBaseUpgradeableV1
/// @notice FROZEN storage-layout snapshot of {AdapterBaseUpgradeable} at the first upgradeable
///         release. Used only as the `referenceContract` for `Upgrades.validateUpgrade` and as the
///         base of the V1 adapter snapshots. Never edit — future adapter storage is validated
///         against this layout. See test/fork/upgrade/*.upgrade.t.sol.
abstract contract AdapterBaseUpgradeableV1 is ILendingAdapter, Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using CurrencyLibrary for Currency;

    struct AdapterMetadata {
        string name;
        uint256 chainId;
    }

    error MarketNotActive();
    error AmountMustBeGreaterThanZero();
    error InvalidRecipient();
    error NativeCurrencyNotSupported();
    error MarketAlreadyRegistered();
    error UnauthorizedCaller();
    error InvalidAuthorizedCaller();
    error AssetMismatch();

    mapping(address => bool) public authorizedCallers;

    event AuthorizedCallerUpdated(address indexed caller, bool allowed);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function __AdapterBase_init(address initialOwner) internal onlyInitializing {
        __Ownable_init(initialOwner);
    }

    modifier validDepositWithdrawParams(uint256 amount, address recipient) {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (recipient == address(0)) revert InvalidRecipient();
        _;
    }

    modifier validCurrency(Currency currency) {
        if (currency.isAddressZero()) revert NativeCurrencyNotSupported();
        _;
    }

    modifier onlyAuthorizedCaller() {
        if (!authorizedCallers[msg.sender]) revert UnauthorizedCaller();
        _;
    }

    function setAuthorizedCaller(address caller, bool allowed) external onlyOwner {
        if (caller == address(0)) revert InvalidAuthorizedCaller();
        authorizedCallers[caller] = allowed;
        emit AuthorizedCallerUpdated(caller, allowed);
    }

    function requiresAllow() external pure virtual returns (bool) {
        return false;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    uint256[49] private __gap;
}
