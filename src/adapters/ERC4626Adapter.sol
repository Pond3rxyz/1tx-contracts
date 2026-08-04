// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {AdapterBaseUpgradeable} from "./base/AdapterBaseUpgradeable.sol";
import {IERC4626} from "../interfaces/IERC4626.sol";

/// @title ERC4626Adapter
/// @notice Shared adapter for ERC-4626 integrations
/// @dev UUPS-upgradeable behind an ERC1967Proxy so its address stays stable across logic changes.
contract ERC4626Adapter is AdapterBaseUpgradeable {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    error InvalidVaultAddress();

    struct MarketConfig {
        Currency currency;
        address vault;
        bool active;
    }

    mapping(bytes32 marketId => MarketConfig) internal markets;

    event MarketRegistered(bytes32 indexed marketId, Currency currency, address vault);
    event MarketDeactivated(bytes32 indexed marketId);
    event Deposited(bytes32 indexed marketId, uint256 assets, uint256 shares, address onBehalfOf);
    event Withdrawn(bytes32 indexed marketId, uint256 assets, uint256 shares, address to);

    /// @notice Initializes the adapter behind a proxy under the default name
    /// @param initialOwner The initial owner of the adapter (can register markets)
    /// @dev Kept for the already-deployed proxies, which were initialized through this path.
    ///      New deployments should use {initializeNamed} so the protocol identity is set.
    function initialize(address initialOwner) external initializer {
        __AdapterBase_init(initialOwner);
    }

    /// @notice Initializes the adapter behind a proxy with an explicit protocol name
    /// @param initialOwner The initial owner of the adapter (can register markets)
    /// @param adapterName_ Protocol identity surfaced by {getAdapterMetadata}, e.g. "Avantis"
    /// @dev This is what makes a new ERC-4626 protocol a config-only listing. Before it, the name
    ///      was baked into bytecode by a per-protocol subclass, so every new protocol needed a new
    ///      contract *and* a deploy script that knew which contract to instantiate.
    ///
    ///      The name is not merely cosmetic and there is deliberately no setter: it is the
    ///      instrument's protocol identity downstream, and that identity is what
    ///      `max_weight_per_protocol` budgets against. Renaming a live adapter would silently
    ///      re-bucket every instrument under it.
    function initializeNamed(address initialOwner, string calldata adapterName_) external initializer {
        __AdapterBase_init(initialOwner);
        _storedAdapterName = adapterName_;
    }

    function registerMarket(Currency currency, address vault) public onlyOwner validCurrency(currency) {
        if (vault == address(0)) revert InvalidVaultAddress();

        if (IERC4626(vault).asset() != Currency.unwrap(currency)) revert AssetMismatch();

        bytes32 marketId = bytes32(uint256(uint160(vault)));
        if (markets[marketId].active) revert MarketAlreadyRegistered();

        markets[marketId] = MarketConfig({currency: currency, vault: vault, active: true});

        emit MarketRegistered(marketId, currency, vault);
    }

    function deactivateMarket(bytes32 marketId) external onlyOwner {
        MarketConfig storage config = markets[marketId];
        if (!config.active) revert MarketNotActive();

        config.active = false;

        emit MarketDeactivated(marketId);
    }

    function hasMarket(bytes32 marketId) external view override returns (bool) {
        return markets[marketId].active;
    }

    /// @notice Returns adapter metadata (name + chainId)
    /// @dev Backward-compatibility shim for the deployed InstrumentRegistry, which reads this in
    ///      registerInstrument and requires `chainId == block.chainid`.
    function getAdapterMetadata() external view virtual returns (AdapterMetadata memory metadata) {
        return AdapterMetadata({name: _adapterName(), chainId: block.chainid});
    }

    /// @notice Converts a yield-token (vault share) amount to its underlying asset value
    /// @dev Backward-compatibility shim for the deployed registry/router ABI.
    function convertToUnderlying(bytes32 marketId, uint256 yieldTokenAmount) external view returns (uint256) {
        return IERC4626(_getActiveMarket(marketId).vault).convertToAssets(yieldTokenAmount);
    }

    /// @notice Human-readable adapter name surfaced in {getAdapterMetadata}
    /// @dev A subclass override replaces this function outright, so for Morpho/Euler/Fluid the
    ///      hardcoded name still wins — those proxies are live and were initialized before the
    ///      stored name existed, and they must keep reporting the name they always have.
    ///      For the generic adapter the name comes from {initializeNamed}, falling back to the
    ///      default when it was deployed through the older {initialize}, or when a pre-existing
    ///      proxy is upgraded to this implementation and the new slot is therefore empty.
    function _adapterName() internal view virtual returns (string memory) {
        return bytes(_storedAdapterName).length == 0 ? "ERC4626 Adapter" : _storedAdapterName;
    }

    function deposit(bytes32 marketId, uint256 amount, address onBehalfOf)
        external
        override
        validDepositWithdrawParams(amount, onBehalfOf)
    {
        MarketConfig storage config = _getActiveMarket(marketId);
        address tokenAddress = Currency.unwrap(config.currency);
        IERC4626 vault = IERC4626(config.vault);

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(tokenAddress).forceApprove(config.vault, amount);

        uint256 shares = vault.deposit(amount, onBehalfOf);

        emit Deposited(marketId, amount, shares, onBehalfOf);
    }

    function withdraw(bytes32 marketId, uint256 amount, address to)
        external
        override
        onlyAuthorizedCaller
        validDepositWithdrawParams(amount, to)
        returns (uint256 assetsWithdrawn)
    {
        MarketConfig storage config = _getActiveMarket(marketId);

        assetsWithdrawn = IERC4626(config.vault).redeem(amount, to, address(this));

        emit Withdrawn(marketId, assetsWithdrawn, amount, to);
    }

    function getYieldToken(bytes32 marketId) external view override returns (address) {
        return _getActiveMarket(marketId).vault;
    }

    function getMarketCurrency(bytes32 marketId) external view override returns (Currency) {
        return _getActiveMarket(marketId).currency;
    }

    function _getActiveMarket(bytes32 marketId) internal view returns (MarketConfig storage config) {
        config = markets[marketId];
        if (!config.active) revert MarketNotActive();
    }

    /// @dev Protocol identity for adapters deployed via {initializeNamed}. Empty on every proxy
    ///      initialized before this field existed, which is why {_adapterName} falls back.
    ///      Appended here, ahead of the gap, so the V1 storage layout is preserved.
    string private _storedAdapterName;

    /// @dev Reserved storage for future fields. Adapter storage is append-only once live.
    uint256[49] private __gap;
}
