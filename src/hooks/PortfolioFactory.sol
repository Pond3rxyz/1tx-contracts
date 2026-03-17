// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PortfolioVault} from "./PortfolioVault.sol";
import {PortfolioHook} from "./PortfolioHook.sol";
import {InstrumentRegistry} from "../registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../registries/SwapPoolRegistry.sol";
import {IPortfolioStrategy} from "../interfaces/IPortfolioStrategy.sol";

/// @title PortfolioFactory
/// @notice Deploys a complete strategy: non-upgradeable vault + PortfolioHook + Uniswap V4 pool
/// @dev Uses CREATE2 for deterministic addresses so the frontend can mine valid hook salts.
///      Vaults are deployed as plain contracts (not proxies) for better explorer compatibility.
///      Strategy logic is centralized in a shared upgradeable PortfolioStrategy contract.
contract PortfolioFactory {
    using PoolIdLibrary for PoolKey;

    /// @dev sqrt(1) * 2^96 — Uniswap V4 sqrtPriceX96 for a 1:1 price ratio
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // ============ Immutables ============

    IPoolManager public immutable poolManager;
    InstrumentRegistry public immutable instrumentRegistry;
    SwapPoolRegistry public immutable swapPoolRegistry;
    IPortfolioStrategy public immutable strategy;

    // ============ Types ============

    struct DeployParams {
        address initialOwner;
        string name;
        string symbol;
        Currency stable;
        PortfolioVault.Allocation[] allocations;
        bytes32 hookSalt;
    }

    // ============ Errors ============

    error InvalidHookAddress(address hook, uint160 expectedFlags);
    error ZeroAddress();

    // ============ Events ============

    event StrategyDeployed(
        address indexed vault,
        address indexed hook,
        PoolId poolId,
        address indexed owner,
        string name,
        string symbol
    );

    // ============ Constructor ============

    constructor(
        IPoolManager _poolManager,
        InstrumentRegistry _instrumentRegistry,
        SwapPoolRegistry _swapPoolRegistry,
        IPortfolioStrategy _strategy
    ) {
        if (address(_poolManager) == address(0)) revert ZeroAddress();
        if (address(_instrumentRegistry) == address(0)) revert ZeroAddress();
        if (address(_swapPoolRegistry) == address(0)) revert ZeroAddress();
        if (address(_strategy) == address(0)) revert ZeroAddress();

        poolManager = _poolManager;
        instrumentRegistry = _instrumentRegistry;
        swapPoolRegistry = _swapPoolRegistry;
        strategy = _strategy;
    }

    // ============ Deploy ============

    /// @notice Deploy a complete strategy: vault + hook + V4 pool
    /// @param params Deployment parameters including allocations and a pre-mined hook salt
    /// @return vault The deployed vault address (also the ERC20 share token)
    /// @return hook The deployed hook address
    /// @return poolId The initialized Uniswap V4 pool ID
    function deploy(DeployParams calldata params)
        external
        returns (address vault, address hook, PoolId poolId)
    {
        // 1. Deploy vault directly via CREATE2 (no proxy — it's a real ERC20)
        vault = _deployVault(params);

        // 2. Deploy hook via CREATE2 with caller-provided salt
        hook = address(
            new PortfolioHook{salt: params.hookSalt}(poolManager, PortfolioVault(vault), params.stable)
        );

        // 3. Validate hook address has correct flag bits
        //    beforeAddLiquidity(1<<11) | beforeRemoveLiquidity(1<<9) | beforeSwap(1<<7)
        //    | afterSwap(1<<6) | beforeSwapReturnDelta(1<<3) = 0xAC8
        if (uint160(hook) & 0x3FFF != 0x0AC8) {
            revert InvalidHookAddress(hook, 0x0AC8);
        }

        // 4. Set hook on vault (factory is temporary owner)
        PortfolioVault(vault).setHook(hook);

        // 5. Initialize pool and transfer ownership
        poolId = _initializePoolAndTransfer(vault, hook, params.stable, params.initialOwner);

        emit StrategyDeployed(vault, hook, poolId, params.initialOwner, params.name, params.symbol);
    }

    function _deployVault(DeployParams calldata params) internal returns (address) {
        bytes32 vaultSalt = _computeVaultSalt(msg.sender, params.name, params.symbol, params.stable);
        return address(
            new PortfolioVault{salt: vaultSalt}(
                PortfolioVault.InitParams({
                    initialOwner: address(this),
                    name: params.name,
                    symbol: params.symbol,
                    stable: params.stable,
                    poolManager: poolManager,
                    instrumentRegistry: instrumentRegistry,
                    swapPoolRegistry: swapPoolRegistry,
                    strategy: strategy,
                    allocations: params.allocations
                })
            )
        );
    }

    function _initializePoolAndTransfer(address vault, address hook, Currency stable, address newOwner)
        internal
        returns (PoolId poolId)
    {
        (Currency c0, Currency c1) = Currency.unwrap(stable) < vault
            ? (stable, Currency.wrap(vault))
            : (Currency.wrap(vault), stable);

        PoolKey memory poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});

        poolManager.initialize(poolKey, SQRT_PRICE_1_1);
        poolId = poolKey.toId();

        PortfolioVault(vault).transferOwnership(newOwner);
    }

    // ============ Internal ============

    function _computeVaultSalt(address sender, string calldata name, string calldata symbol, Currency stable)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(sender, name, symbol, stable));
    }
}
