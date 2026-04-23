// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ERC4626Adapter} from "./ERC4626Adapter.sol";

/// @title FluidAdapter
/// @notice Compatibility wrapper for Fluid ERC-4626 markets
contract FluidAdapter is ERC4626Adapter {
    constructor(address initialOwner) ERC4626Adapter(initialOwner, "Fluid Lending") {}

    function registerFToken(Currency currency, address fToken) external {
        registerMarket(currency, fToken);
    }
}
