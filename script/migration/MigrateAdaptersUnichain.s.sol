// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {InstrumentRegistry} from "../../src/registries/InstrumentRegistry.sol";
import {MorphoAdapter} from "../../src/adapters/MorphoAdapter.sol";
import {EulerAdapter} from "../../src/adapters/EulerAdapter.sol";

/// @title AdapterMigrator
/// @notice One-shot helper that atomically swaps the Unichain lending adapters for the new
///         `src/adapters` implementations. Everything happens inside `migrate()` so it lands as a
///         SINGLE transaction: deploy new adapters, register their markets, authorize the router,
///         re-point every instrument, then hand ownership back to the original owner.
/// @dev The registry's admin functions are `onlyOwner`, so this contract must own the registry for
///      the duration of `migrate()`. The deploy script transfers registry ownership to this
///      migrator in a prior tx, then calls `migrate()`; the migrator returns ownership at the end.
///      If `migrate()` ever reverts after ownership was moved, `rescueRegistryOwnership()` returns
///      it to `finalOwner`.
///
///      Instrument IDs are independent of the adapter (`id = f(chainId, vault, marketId)`), and the
///      new adapters derive the same `marketId = bytes32(uint160(vault))`, so re-pointing keeps the
///      exact same instrument IDs — only the stored adapter address changes.
contract AdapterMigrator {
    error NotAdmin();
    error PostconditionFailed();

    /// @notice EOA that deployed this migrator and is allowed to drive it (the original owner).
    address public immutable admin;
    /// @notice The address ownership of the registry and new adapters is returned to.
    address public immutable finalOwner;

    InstrumentRegistry public immutable registry;
    address public immutable router;
    Currency public immutable underlying;

    address public immutable gauntletVault;
    address public immutable eeVault;
    bytes32 public immutable gauntletInstrumentId;
    bytes32 public immutable eeInstrumentId;

    /// @notice New adapters deployed by `migrate()` (0 until it runs).
    MorphoAdapter public newMorphoAdapter;
    EulerAdapter public newEulerAdapter;

    constructor(
        InstrumentRegistry _registry,
        address _router,
        address _finalOwner,
        Currency _underlying,
        address _gauntletVault,
        address _eeVault,
        bytes32 _gauntletInstrumentId,
        bytes32 _eeInstrumentId
    ) {
        admin = msg.sender;
        registry = _registry;
        router = _router;
        finalOwner = _finalOwner;
        underlying = _underlying;
        gauntletVault = _gauntletVault;
        eeVault = _eeVault;
        gauntletInstrumentId = _gauntletInstrumentId;
        eeInstrumentId = _eeInstrumentId;
    }

    /// @notice Performs the full adapter swap atomically. Reverts (rolls everything back) on any error.
    function migrate() external {
        if (msg.sender != admin) revert NotAdmin();

        // 1. Deploy the new adapters; this migrator owns them until step 5.
        MorphoAdapter morpho = new MorphoAdapter(address(this));
        EulerAdapter euler = new EulerAdapter(address(this));
        newMorphoAdapter = morpho;
        newEulerAdapter = euler;

        // 2. Register the same markets on the new adapters (asset is verified against the vault).
        morpho.registerVault(underlying, gauntletVault);
        euler.registerVault(underlying, eeVault);

        // 3. Authorize the production router to call withdraw() on the new adapters.
        morpho.setAuthorizedCaller(router, true);
        euler.setAuthorizedCaller(router, true);

        // 4. Re-point each instrument. Same instrumentId, same marketId, new adapter address.
        bytes32 gauntletMarketId = bytes32(uint256(uint160(gauntletVault)));
        bytes32 eeMarketId = bytes32(uint256(uint160(eeVault)));

        registry.unregisterInstrument(gauntletInstrumentId);
        registry.registerInstrument(gauntletVault, gauntletMarketId, address(morpho));

        registry.unregisterInstrument(eeInstrumentId);
        registry.registerInstrument(eeVault, eeMarketId, address(euler));

        // 5. Return ownership of the new adapters and the registry to the original owner.
        morpho.transferOwnership(finalOwner);
        euler.transferOwnership(finalOwner);
        registry.transferOwnership(finalOwner);

        // 6. Postconditions: instruments must now resolve to the new adapters.
        (address gauntletAdapter,) = registry.instruments(gauntletInstrumentId);
        (address eeAdapter,) = registry.instruments(eeInstrumentId);
        if (gauntletAdapter != address(morpho) || eeAdapter != address(euler)) {
            revert PostconditionFailed();
        }
    }

    /// @notice Safety valve: returns registry ownership to `finalOwner` if `migrate()` failed
    ///         after ownership had already been transferred to this migrator.
    function rescueRegistryOwnership() external {
        if (msg.sender != admin) revert NotAdmin();
        registry.transferOwnership(finalOwner);
    }
}

/// @title MigrateAdaptersUnichain
/// @notice Deploys the migrator, hands it registry ownership, and runs the atomic swap on Unichain.
///
/// Dry run (simulation against live state, no state change):
///   forge script script/MigrateAdaptersUnichain.s.sol:MigrateAdaptersUnichain --rpc-url unichain -vvvv
///
/// Broadcast (signer MUST be the current owner of the registry + adapters):
///   forge script script/MigrateAdaptersUnichain.s.sol:MigrateAdaptersUnichain \
///     --rpc-url unichain --account <keystore> --broadcast -vvvv
contract MigrateAdaptersUnichain is Script {
    // --- Unichain mainnet constants (verified on-chain against docs/deployments.md) ---
    InstrumentRegistry constant REGISTRY = InstrumentRegistry(0x94CC7106f7741FA2d374Ca7b808645fF43b6d2a3);
    address constant ROUTER = 0xde80Ed3CeBdbf688fE12792BDC5d16f4401cC4f2;
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;

    address constant GAUNTLET_VAULT = 0x38f4f3B6533de0023b9DCd04b02F93d36ad1F9f9; // Morpho Gauntlet USDC-C
    address constant EE_VAULT = 0x6eAe95ee783e4D862867C4e0E4c3f4B95AA682Ba; // Euler eeUSDC

    bytes32 constant GAUNTLET_INSTRUMENT_ID = 0x000000824b822ab054373ab8475e79d5e8f5c5105ca79632b92aad9db3b4ec87;
    bytes32 constant EE_INSTRUMENT_ID = 0x000000820683b130b1d45f5f6374452f1cb9389a8449014179901d2880a3c2c7;

    function run() external {
        require(block.chainid == 130, "not Unichain mainnet");

        address currentOwner = REGISTRY.owner();

        console.log("================================================");
        console.log("  Migrate Unichain adapters (atomic swap)");
        console.log("================================================");
        console.log("Registry:      ", address(REGISTRY));
        console.log("Current owner: ", currentOwner);
        console.log("Router:        ", ROUTER);

        vm.startBroadcast();

        // The broadcaster must be the current owner so it can transfer ownership to the migrator
        // and later act as the migrator's admin.
        require(msg.sender == currentOwner, "broadcaster is not the registry owner");

        AdapterMigrator migrator = new AdapterMigrator(
            REGISTRY,
            ROUTER,
            currentOwner, // finalOwner: hand everything back to the current owner
            Currency.wrap(USDC),
            GAUNTLET_VAULT,
            EE_VAULT,
            GAUNTLET_INSTRUMENT_ID,
            EE_INSTRUMENT_ID
        );
        console.log("Migrator:      ", address(migrator));

        // Grant the migrator temporary ownership, then run the atomic swap.
        REGISTRY.transferOwnership(address(migrator));
        migrator.migrate();

        vm.stopBroadcast();

        console.log("\n--- Result ---");
        console.log("New Morpho adapter:", address(migrator.newMorphoAdapter()));
        console.log("New Euler adapter: ", address(migrator.newEulerAdapter()));
        console.log("Registry owner:    ", REGISTRY.owner());
        require(REGISTRY.owner() == currentOwner, "registry ownership not returned");

        (address gauntletAdapter,) = REGISTRY.instruments(GAUNTLET_INSTRUMENT_ID);
        (address eeAdapter,) = REGISTRY.instruments(EE_INSTRUMENT_ID);
        require(gauntletAdapter == address(migrator.newMorphoAdapter()), "gauntlet not re-pointed");
        require(eeAdapter == address(migrator.newEulerAdapter()), "euler not re-pointed");
        console.log("Both instruments re-pointed to new adapters.");
        console.log("================================================");
    }
}
