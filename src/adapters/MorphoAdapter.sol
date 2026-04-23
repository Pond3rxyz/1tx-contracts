// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ERC4626Adapter} from "./ERC4626Adapter.sol";

/// @title MorphoAdapter
/// @notice Compatibility wrapper for Morpho ERC-4626 markets
contract MorphoAdapter is ERC4626Adapter {
    constructor(address initialOwner) ERC4626Adapter(initialOwner, "Morpho Vaults V2") {}

    function registerVault(Currency currency, address vault) external {
        registerMarket(currency, vault);
    }
}
