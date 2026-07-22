// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {InstrumentRegistry} from "../src/registries/InstrumentRegistry.sol";
import {InstrumentIdLib} from "../src/libraries/InstrumentIdLib.sol";

import {ConfigReader, DeployedConfig} from "./utils/ConfigReader.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {IERC4626} from "../src/interfaces/IERC4626.sol";
import {MorphoAdapter} from "../src/adapters/MorphoAdapter.sol";
import {EulerAdapter} from "../src/adapters/EulerAdapter.sol";
import {FluidAdapter} from "../src/adapters/FluidAdapter.sol";

/// @title RegisterInstruments
/// @notice Registers any ERC-4626 vault instruments listed in NetworkConfig.json that are not
///         yet registered on the already-deployed infrastructure. Idempotent: existing
///         instruments are skipped, only missing ones are registered.
/// @dev Source of truth is `script/config/NetworkConfig.json`. To add an instrument, add its
///      address under `networks.<net>.protocols.<morpho|eulerEarn|fluid>.<vaults|fTokens>` and
///      re-run. The underlying asset is read on-chain from the vault, so no token config is needed.
///
///      Adapters are called through the current upgradeable `src/adapters/` contracts
///      (MorphoAdapter / EulerAdapter / FluidAdapter). The addresses come from
///      `NetworkConfig.json.networks.<net>.deployed.adapters`, which point at the migrated
///      UUPS proxies (registerVault / registerFToken).
///
///      Not covered (current config has no enumerable market list for these): Aave (per-token,
///      only a pool address) and Compound (comets; base token not exposed by the deployed
///      interface). Register those separately if needed.
///
/// Usage (dry run):
///   forge script script/RegisterInstruments.s.sol:RegisterInstruments --rpc-url <network> -vvvv
///
/// Broadcast (signer MUST own both the InstrumentRegistry and the target adapter):
///   forge script script/RegisterInstruments.s.sol:RegisterInstruments \
///     --rpc-url <network> --account <keystore> --broadcast -vvvv
contract RegisterInstruments is ConfigReader {
    /// @dev Selects which deployed adapter entrypoint to use for a vault list.
    enum VaultKind {
        MorphoVault, // DeployedMorphoAdapter.registerVault
        EulerVault, // DeployedEulerAdapter.registerVault
        FluidFToken // DeployedFluidAdapter.registerFToken
    }

    InstrumentRegistry public registry;

    string internal config;
    string internal netPath;

    uint256 public registered;
    uint256 public skipped;

    function run() external {
        string memory networkName = detectNetworkFromChainId(block.chainid);
        DeployedConfig memory deployed = getDeployedConfig(networkName);

        registry = InstrumentRegistry(deployed.instrumentRegistry);
        config = vm.readFile("script/config/NetworkConfig.json");
        netPath = string.concat(".networks.", networkName);

        console.log("\n================================================");
        console.log("  Register Missing Instruments");
        console.log("================================================");
        console.log("Network:  ", networkName);
        console.log("Chain ID: ", block.chainid);
        console.log("Registry: ", address(registry));

        vm.startBroadcast();
        _registerVaultList("morpho", "vaults", deployed.adapters.morpho, VaultKind.MorphoVault);
        _registerVaultList("eulerEarn", "vaults", deployed.adapters.euler, VaultKind.EulerVault);
        _registerVaultList("fluid", "fTokens", deployed.adapters.fluid, VaultKind.FluidFToken);
        vm.stopBroadcast();

        console.log("\n--- Summary ---");
        console.log("  Registered:", registered);
        console.log("  Skipped:   ", skipped);
        console.log("================================================\n");
    }

    /// @notice Iterates every vault under a protocol's config list and registers the missing ones.
    /// @param protocolKey JSON key under `protocols` (e.g. "morpho", "eulerEarn", "fluid")
    /// @param listKey JSON key holding the address map (e.g. "vaults", "fTokens")
    /// @param adapter Deployed adapter address for this protocol (skipped if zero)
    /// @param kind Which deployed adapter entrypoint to use
    function _registerVaultList(string memory protocolKey, string memory listKey, address adapter, VaultKind kind)
        internal
    {
        if (adapter == address(0)) {
            console.log(string.concat("\n", protocolKey, ": no adapter deployed, skipping"));
            return;
        }

        string memory listPath = string.concat(netPath, ".protocols.", protocolKey, ".", listKey);
        if (!vm.keyExistsJson(config, listPath)) {
            console.log(string.concat("\n", protocolKey, ": no ", listKey, " in config, skipping"));
            return;
        }

        console.log(string.concat("\n--- ", protocolKey, " ---"));
        string[] memory names = vm.parseJsonKeys(config, listPath);
        for (uint256 i = 0; i < names.length; i++) {
            address vault = vm.parseJsonAddress(config, string.concat(listPath, ".", names[i]));
            _registerVault(names[i], vault, adapter, kind);
        }
    }

    /// @notice Registers a single vault as an instrument if it is not already registered.
    function _registerVault(string memory name, address vault, address adapter, VaultKind kind) internal {
        bytes32 marketId = bytes32(uint256(uint160(vault)));
        bytes32 instrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, vault, marketId);

        if (_isInstrumentRegistered(instrumentId)) {
            console.log("  SKIP (exists):", name);
            skipped++;
            return;
        }

        // Underlying is read straight from the vault so config never has to track it.
        Currency currency = Currency.wrap(IERC4626(vault).asset());

        if (!ILendingAdapter(adapter).hasMarket(marketId)) {
            if (kind == VaultKind.MorphoVault) {
                MorphoAdapter(adapter).registerVault(currency, vault);
            } else if (kind == VaultKind.EulerVault) {
                EulerAdapter(adapter).registerVault(currency, vault);
            } else {
                FluidAdapter(adapter).registerFToken(currency, vault);
            }
        }

        registry.registerInstrument(vault, marketId, adapter);
        registered++;

        console.log("  Registered:", name);
        console.log("    vault:", vault);
        console.log("    instrumentId:", vm.toString(instrumentId));
    }

    function _isInstrumentRegistered(bytes32 instrumentId) internal view returns (bool) {
        (address adapter,) = registry.instruments(instrumentId);
        return adapter != address(0);
    }
}
