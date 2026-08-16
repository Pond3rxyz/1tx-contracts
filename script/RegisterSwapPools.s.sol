// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {SwapPoolRegistry} from "../src/registries/SwapPoolRegistry.sol";
import {ConfigReader, NetworkConfig, DeployedConfig, SwapPoolConfig} from "./utils/ConfigReader.sol";

/// @title RegisterSwapPools
/// @notice Registers the `swapPools` routes from `NetworkConfig.json` on a live
///         `SwapPoolRegistry`, without touching the routes already wired.
///
/// @dev **Use this, not `Deploy.s.sol`, on a chain that is already in production.** Swap-pool
///      registration previously existed only as `Deploy._registerSwapPools`, step 4 of an
///      eight-step `run()` that also deploys the registries, the adapters, the router and the
///      whole CCTP mesh. There was no way to add one route to a live chain, which is why Monad
///      shipped with `swapPools: []` and stayed USDC-native: the AUSD route could be written into
///      config but never registered.
///
///      Both directions are registered per route, matching `Deploy._registerSwapPools`. A
///      one-directional entry is a deposit that works and a withdrawal that reverts.
///
///      Per route, diffed against `defaultSwapPools` before writing:
///        - both directions already hold this exact PoolKey -> `SKIP (exists)`, zero transactions
///        - unregistered                                    -> registered, logged `SET`
///        - registered with a *different* PoolKey           -> **abort**, printing old and new
///
///      The mismatch case aborts rather than overwriting because repointing a live route changes
///      where every future deposit on that pair executes. A route whose liquidity moved to another
///      fee tier is deliberate work, so it lives behind a separate entry point:
///
///      ```
///      forge script script/RegisterSwapPools.s.sol:RegisterSwapPools --sig "runForce()" ...
///      ```
///
///      A route naming a token absent from the `tokens` map **aborts**. `Deploy` logs
///      `SKIPPED (token not found)` and carries on, which is how a listing gets quietly lost —
///      the chain deploys clean, with no route and no error. `test_monadAusdTokenResolves` in
///      `test/unit/NetworkConfig.t.sol` pins the same thing from the config side.
///
///      This script does **not** verify the pool holds liquidity, and registering a dead pool is
///      not something the registry can detect: `PoolKey` is just five fields. Measure the tier
///      first — see `test/fork/monad/AusdUsdcRoute.fork.t.sol`, where four AUSD/USDC tiers are
///      initialised on Monad and only fee 50 / tickSpacing 1 holds anything.
///
/// Usage (dry run):
///   forge script script/RegisterSwapPools.s.sol:RegisterSwapPools --rpc-url <network> \
///     --sender 0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73 -vvvv
///
/// Broadcast (signer MUST own the SwapPoolRegistry):
///   forge script script/RegisterSwapPools.s.sol:RegisterSwapPools --rpc-url <network> \
///     --account <keystore> --sender 0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73 --broadcast -vvvv
contract RegisterSwapPools is Script, ConfigReader {
    SwapPoolRegistry public registry;
    string internal networkName;

    uint256 public registeredCount;
    uint256 public skippedCount;

    function run() external {
        _run({force: false});
    }

    /// @notice Same, but overwrites a route already registered with a different PoolKey.
    function runForce() external {
        _run({force: true});
    }

    function _run(bool force) internal {
        networkName = detectNetworkFromChainId(block.chainid);
        require(isNetworkSupported(networkName), "Unsupported network");

        NetworkConfig memory config = getNetworkConfig(networkName);
        DeployedConfig memory deployed = getDeployedConfig(networkName);

        require(deployed.swapPoolRegistry != address(0), "swapPoolRegistry missing from config");
        registry = SwapPoolRegistry(deployed.swapPoolRegistry);

        console.log("\n================================================");
        console.log("  Register Swap Pools");
        console.log("================================================");
        console.log("Network:  ", networkName);
        console.log("Chain ID: ", block.chainid);
        console.log("Registry: ", address(registry));
        if (force) console.log("Mode:      FORCE (will overwrite mismatches)");

        if (config.swapPools.length == 0) {
            console.log("\n  No swap pools configured for this network.");
            return;
        }

        vm.startBroadcast();
        for (uint256 i = 0; i < config.swapPools.length; i++) {
            _registerRoute(config.swapPools[i], force);
        }
        vm.stopBroadcast();

        console.log("\n--- Summary ---");
        console.log("  Routes registered:", registeredCount);
        console.log("  Skipped (exists): ", skippedCount);
        console.log("================================================\n");
    }

    function _registerRoute(SwapPoolConfig memory poolConfig, bool force) internal {
        string memory label = string.concat(poolConfig.tokenIn, "/", poolConfig.tokenOut);

        address tokenIn = getTokenAddressBySymbol(networkName, poolConfig.tokenIn);
        address tokenOut = getTokenAddressBySymbol(networkName, poolConfig.tokenOut);

        // Abort rather than skip. A route silently dropped for an unresolvable symbol is a chain
        // that deploys clean and cannot swap.
        require(tokenIn != address(0), string.concat("token not in `tokens` map: ", poolConfig.tokenIn));
        require(tokenOut != address(0), string.concat("token not in `tokens` map: ", poolConfig.tokenOut));

        // Uniswap V4 requires currency0 < currency1; the registry validates the PoolKey against
        // the pair in either order, but the key itself has to be sorted or it addresses no pool.
        (Currency currency0, Currency currency1) = tokenIn < tokenOut
            ? (Currency.wrap(tokenIn), Currency.wrap(tokenOut))
            : (Currency.wrap(tokenOut), Currency.wrap(tokenIn));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: poolConfig.fee,
            tickSpacing: poolConfig.tickSpacing,
            hooks: IHooks(poolConfig.hooks)
        });

        Currency inCurrency = Currency.wrap(tokenIn);
        Currency outCurrency = Currency.wrap(tokenOut);

        bool forwardOk = _checkDirection(label, inCurrency, outCurrency, key, force);
        bool reverseOk = _checkDirection(label, outCurrency, inCurrency, key, force);

        if (forwardOk && reverseOk) {
            console.log(string.concat("  SKIP (exists): ", label));
            skippedCount++;
            return;
        }

        // Re-registering a direction that already matches is a no-op write, and keeping both in
        // one call is what stops a half-registered pair existing.
        registry.registerDefaultSwapPool(inCurrency, outCurrency, key);
        registry.registerDefaultSwapPool(outCurrency, inCurrency, key);

        registeredCount++;
        console.log(string.concat("  SET: ", label, " (bidirectional)"));
        console.log("    fee:        ", uint256(poolConfig.fee));
        console.log("    tickSpacing:", vm.toString(int256(poolConfig.tickSpacing)));
        console.log("    hooks:      ", poolConfig.hooks);
    }

    /// @return matches True when this direction already holds exactly `key`.
    function _checkDirection(
        string memory label,
        Currency currencyIn,
        Currency currencyOut,
        PoolKey memory key,
        bool force
    ) internal view returns (bool matches) {
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            registry.defaultSwapPools(keccak256(abi.encode(currencyIn, currencyOut)));

        // `fee == 0` is the registry's own "unregistered" sentinel — see
        // {SwapPoolRegistry-getDefaultSwapPool}, which reverts on it.
        if (fee == 0) return false;

        matches = Currency.unwrap(c0) == Currency.unwrap(key.currency0)
            && Currency.unwrap(c1) == Currency.unwrap(key.currency1) && fee == key.fee && tickSpacing == key.tickSpacing
            && address(hooks) == address(key.hooks);

        if (!matches && !force) {
            console.log(string.concat("\n  MISMATCH on ", label));
            console.log("    registered fee/tickSpacing:", uint256(fee), vm.toString(int256(tickSpacing)));
            console.log("    config     fee/tickSpacing:", uint256(key.fee), vm.toString(int256(key.tickSpacing)));
            console.log("    registered hooks:", address(hooks));
            console.log("    config     hooks:", address(key.hooks));
            revert("route already registered with a different PoolKey; re-run with --sig runForce()");
        }
    }
}
