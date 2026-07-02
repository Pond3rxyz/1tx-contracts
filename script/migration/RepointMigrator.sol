// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {InstrumentRegistry} from "../../src/registries/InstrumentRegistry.sol";

/// @title RepointMigrator
/// @notice Atomically re-points a batch of instruments from their old adapters to new ones in a
///         SINGLE transaction, then returns registry ownership to the original owner.
/// @dev The registry has no in-place update, so each re-point is `unregister` + `register`. Doing
///      the whole batch inside one `repoint()` call means no instrument is ever observably
///      unregistered to other transactions — there is no downtime window.
///
///      Adapter deployment, market registration and router authorization are done BEFORE this by
///      the migration script (they have zero production impact — the old adapters keep serving until
///      the re-point lands), so this contract only ever needs ownership of the registry.
///
///      Usage: the owner transfers registry ownership to this migrator, calls `repoint(...)`, and
///      the migrator hands ownership back at the end. `rescueRegistryOwnership()` recovers ownership
///      if `repoint()` ever reverts after ownership was moved.
contract RepointMigrator {
    error NotAdmin();
    error LengthMismatch();
    error PostconditionFailed();

    /// @notice EOA that deployed this migrator and is allowed to drive it (the original owner).
    address public immutable admin;
    /// @notice Address registry ownership is returned to.
    address public immutable finalOwner;
    /// @notice The registry being migrated.
    InstrumentRegistry public immutable registry;

    constructor(InstrumentRegistry _registry, address _finalOwner) {
        admin = msg.sender;
        registry = _registry;
        finalOwner = _finalOwner;
    }

    /// @notice Re-points every instrument to its new adapter atomically, then returns ownership.
    /// @param instrumentIds Existing instrument IDs to move (must currently be registered).
    /// @param executionAddresses The original execution address each instrument was registered with
    ///        (vault for ERC-4626, Aave pool for Aave, Comet for Compound). Must reproduce the same
    ///        instrumentId so the ID is preserved.
    /// @param marketIds The market ID on the new adapter for each instrument.
    /// @param newAdapters The new adapter each instrument should point to.
    function repoint(
        bytes32[] calldata instrumentIds,
        address[] calldata executionAddresses,
        bytes32[] calldata marketIds,
        address[] calldata newAdapters
    ) external {
        if (msg.sender != admin) revert NotAdmin();
        uint256 n = instrumentIds.length;
        if (executionAddresses.length != n || marketIds.length != n || newAdapters.length != n) {
            revert LengthMismatch();
        }

        for (uint256 i; i < n; ++i) {
            registry.unregisterInstrument(instrumentIds[i]);
            registry.registerInstrument(executionAddresses[i], marketIds[i], newAdapters[i]);
        }

        registry.transferOwnership(finalOwner);

        // Postconditions: every instrument now resolves to its new adapter, same ID.
        for (uint256 i; i < n; ++i) {
            (address adapter,) = registry.instruments(instrumentIds[i]);
            if (adapter != newAdapters[i]) revert PostconditionFailed();
        }
    }

    /// @notice Safety valve: returns registry ownership to `finalOwner` if `repoint()` reverted
    ///         after ownership had already been transferred to this migrator.
    function rescueRegistryOwnership() external {
        if (msg.sender != admin) revert NotAdmin();
        registry.transferOwnership(finalOwner);
    }
}
