// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ERC4626Adapter} from "./ERC4626Adapter.sol";

/// @title EulerAdapter
/// @notice Compatibility wrapper for Euler ERC-4626 markets
contract EulerAdapter is ERC4626Adapter {
    constructor(address initialOwner) ERC4626Adapter(initialOwner, "Euler Earn") {}

    function registerVault(Currency currency, address vault) external {
        registerMarket(currency, vault);
    }
}
