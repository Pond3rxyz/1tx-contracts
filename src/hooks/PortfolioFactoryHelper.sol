// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PortfolioVault} from "./PortfolioVault.sol";
import {PortfolioHook} from "./PortfolioHook.sol";
import {InstrumentRegistry} from "../registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../registries/SwapPoolRegistry.sol";
import {IPortfolioStrategy} from "../interfaces/IPortfolioStrategy.sol";

/// @title PortfolioFactoryHelper
/// @notice Read-only helper for computing deterministic addresses of vaults and hooks.
///         Separated from PortfolioFactory to keep the factory under the EIP-170 size limit.
contract PortfolioFactoryHelper {
    address public immutable factory;
    IPoolManager public immutable poolManager;
    InstrumentRegistry public immutable instrumentRegistry;
    SwapPoolRegistry public immutable swapPoolRegistry;
    IPortfolioStrategy public immutable strategy;

    constructor(
        address _factory,
        IPoolManager _poolManager,
        InstrumentRegistry _instrumentRegistry,
        SwapPoolRegistry _swapPoolRegistry,
        IPortfolioStrategy _strategy
    ) {
        factory = _factory;
        poolManager = _poolManager;
        instrumentRegistry = _instrumentRegistry;
        swapPoolRegistry = _swapPoolRegistry;
        strategy = _strategy;
    }

    /// @notice Compute the deterministic vault address before deployment
    function computeVaultAddress(
        address sender,
        string calldata name,
        string calldata symbol,
        Currency stable,
        PortfolioVault.Allocation[] calldata allocations
    ) external view returns (address) {
        bytes32 vaultSalt = keccak256(abi.encode(sender, name, symbol, stable));
        PortfolioVault.InitParams memory initParams = PortfolioVault.InitParams({
            initialOwner: factory,
            name: name,
            symbol: symbol,
            stable: stable,
            poolManager: poolManager,
            instrumentRegistry: instrumentRegistry,
            swapPoolRegistry: swapPoolRegistry,
            strategy: strategy,
            allocations: allocations
        });

        bytes memory creationCode = abi.encodePacked(type(PortfolioVault).creationCode, abi.encode(initParams));

        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), factory, vaultSalt, keccak256(creationCode)));
        return address(uint160(uint256(hash)));
    }

    /// @notice Compute the deterministic hook address for a given vault and salt
    function computeHookAddress(PortfolioVault vault, Currency stable, bytes32 salt) external view returns (address) {
        bytes memory hookCreationCode =
            abi.encodePacked(type(PortfolioHook).creationCode, abi.encode(poolManager, vault, stable));

        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), factory, salt, keccak256(hookCreationCode)));
        return address(uint160(uint256(hash)));
    }

    /// @notice Get the creation code hash for PortfolioHook with given constructor args
    /// @dev Frontend uses this to mine a salt that produces an address with correct flag bits
    function getHookCreationCodeHash(PortfolioVault vault, Currency stable) external view returns (bytes32) {
        bytes memory hookCreationCode =
            abi.encodePacked(type(PortfolioHook).creationCode, abi.encode(poolManager, vault, stable));
        return keccak256(hookCreationCode);
    }
}
