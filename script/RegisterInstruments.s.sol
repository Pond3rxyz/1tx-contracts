// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {InstrumentRegistry} from "../src/registries/InstrumentRegistry.sol";
import {InstrumentIdLib} from "../src/libraries/InstrumentIdLib.sol";

import {ConfigReader, DeployedConfig} from "./utils/ConfigReader.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {IERC4626} from "../src/interfaces/IERC4626.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";

/// @title RegisterInstruments
/// @notice Registers every ERC-4626 vault listed in NetworkConfig.json that is not yet registered,
///         deploying the protocol's adapter first if it does not exist. Idempotent: existing
///         adapters and instruments are skipped, only missing ones are created.
///
/// @dev **Adding a new ERC-4626 protocol is a config change, with no Solidity and no new script.**
///      Add a block under `networks.<net>.protocols.<key>`:
///
///      ```json
///      "avantis": {
///          "adapter": { "key": "avantis", "name": "Avantis" },
///          "vaults":  { "avUSDC": "0x9447…E7f9" }
///      }
///      ```
///
///      plus `deployed.adapters.<adapter.key>` (the zero address if it still needs deploying), and
///      re-run. That is the whole listing.
///
///      Three things used to stand in the way and no longer do:
///
///      1. *The adapter name was bytecode.* Every protocol needed a subclass overriding
///         `_adapterName()`, so a generic deploy path could not exist — something had to choose
///         which contract to instantiate. The name now comes from
///         {ERC4626Adapter-initializeNamed}, so one contract serves every ERC-4626 protocol. The
///         Morpho/Euler/Fluid subclasses are kept only because their proxies are already live.
///      2. *A `VaultKind` enum picked between `registerVault` / `registerFToken`.* Those were
///         always thin wrappers over the base `registerMarket`, which is `public onlyOwner` on
///         every deployed adapter — verified on-chain, not assumed. This calls it directly.
///      3. *The vault list key differed per protocol* (`vaults` vs `fTokens`). Both are read.
///
///      The underlying asset is read on-chain from the vault, so config never tracks it. Aave and
///      Compound are out of scope by construction: neither exposes an enumerable vault list.
///
///      Deploying and registering share one script deliberately — an adapter registered without
///      `setAuthorizedCaller(router)` ships a market where deposits succeed and every exit reverts
///      `UnauthorizedCaller`. Keeping both steps here means that state cannot be reached by
///      running one script and forgetting the other, and the post-conditions below enforce it.
///
/// Usage (dry run):
///   forge script script/RegisterInstruments.s.sol:RegisterInstruments --rpc-url <network> \
///     --sender 0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73 -vvvv
///
/// Broadcast (signer MUST own both the InstrumentRegistry and the target adapter):
///   forge script script/RegisterInstruments.s.sol:RegisterInstruments --rpc-url <network> \
///     --account <keystore> --sender 0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73 --broadcast -vvvv
///
/// After a run that deployed an adapter, write the printed proxy address into
/// `NetworkConfig.json` at `deployed.adapters.<key>` and into `docs/deployments.md`.
contract RegisterInstruments is ConfigReader {
    /// @dev The two names a vault list goes by in config.
    string[2] internal LIST_KEYS = ["vaults", "fTokens"];

    InstrumentRegistry public registry;
    address public router;

    string internal config;
    string internal netPath;

    uint256 public registered;
    uint256 public skipped;
    uint256 public adaptersDeployed;

    function run() external {
        string memory networkName = detectNetworkFromChainId(block.chainid);
        DeployedConfig memory deployed = getDeployedConfig(networkName);

        registry = InstrumentRegistry(deployed.instrumentRegistry);
        router = deployed.swapDepositorRouter;
        config = vm.readFile(CONFIG_PATH);
        netPath = string.concat(".networks.", networkName);

        require(address(registry) != address(0), "instrumentRegistry missing from config");
        require(router != address(0), "swapDepositorRouter missing from config");

        console.log("\n================================================");
        console.log("  Register Missing Instruments");
        console.log("================================================");
        console.log("Network:  ", networkName);
        console.log("Chain ID: ", block.chainid);
        console.log("Registry: ", address(registry));
        console.log("Router:   ", router);

        // Every protocol in config is considered; those without an `adapter` block (Aave,
        // Compound — neither exposes an enumerable vault list) drop out in _registerProtocol.
        // Enumerating rather than hardcoding is what leaves *no* Solidity edit for a new listing.
        string[] memory protocolKeys = vm.parseJsonKeys(config, string.concat(netPath, ".protocols"));

        vm.startBroadcast();
        for (uint256 i = 0; i < protocolKeys.length; i++) {
            _registerProtocol(protocolKeys[i]);
        }
        vm.stopBroadcast();

        console.log("\n--- Summary ---");
        console.log("  Adapters deployed:", adaptersDeployed);
        console.log("  Instruments registered:", registered);
        console.log("  Skipped:   ", skipped);
        console.log("================================================\n");
    }

    /// @notice Resolves a protocol's adapter (deploying it if absent) and registers its vaults.
    function _registerProtocol(string memory protocolKey) internal {
        string memory protoPath = string.concat(netPath, ".protocols.", protocolKey);
        if (!vm.keyExistsJson(config, protoPath)) return;

        // No `adapter` block means the protocol is not an ERC-4626 listing (Aave, Compound).
        string memory adapterPath = string.concat(protoPath, ".adapter");
        if (!vm.keyExistsJson(config, adapterPath)) return;

        string memory listPath = _vaultListPath(protoPath);
        if (bytes(listPath).length == 0) {
            console.log(string.concat("\n", protocolKey, ": no vault list in config, skipping"));
            return;
        }

        string[] memory names = vm.parseJsonKeys(config, listPath);
        if (names.length == 0) return;

        console.log(string.concat("\n--- ", protocolKey, " ---"));

        string memory adapterKey = vm.parseJsonString(config, string.concat(adapterPath, ".key"));
        string memory adapterName = vm.parseJsonString(config, string.concat(adapterPath, ".name"));
        address adapter = _resolveAdapter(adapterKey, adapterName);

        for (uint256 i = 0; i < names.length; i++) {
            address vault = vm.parseJsonAddress(config, string.concat(listPath, ".", names[i]));
            _registerVault(names[i], vault, adapter);
        }
    }

    /// @notice Returns the config path of a protocol's vault map, or "" if it has none.
    function _vaultListPath(string memory protoPath) internal view returns (string memory) {
        for (uint256 i = 0; i < LIST_KEYS.length; i++) {
            string memory candidate = string.concat(protoPath, ".", LIST_KEYS[i]);
            if (vm.keyExistsJson(config, candidate)) return candidate;
        }
        return "";
    }

    /// @notice Reads the deployed adapter for a protocol, deploying + authorizing it when absent.
    function _resolveAdapter(string memory adapterKey, string memory adapterName) internal returns (address) {
        string memory path = string.concat(netPath, ".deployed.adapters.", adapterKey);
        address adapter = vm.keyExistsJson(config, path) ? vm.parseJsonAddress(config, path) : address(0);

        if (adapter != address(0)) {
            console.log("  adapter (from config):", adapter);
        } else {
            ERC4626Adapter impl = new ERC4626Adapter();
            adapter = address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(ERC4626Adapter.initializeNamed, (msg.sender, adapterName))
                )
            );
            adaptersDeployed++;

            console.log(string.concat("  DEPLOYED adapter '", adapterName, "'"));
            console.log("    implementation:", address(impl));
            console.log("    proxy:         ", adapter);
            console.log("    -> write this proxy into NetworkConfig.json deployed.adapters and docs/deployments.md");
        }

        // Idempotent, and asserted rather than assumed: an adapter the router cannot call is a
        // market where deposits succeed and every withdrawal reverts.
        if (!ERC4626Adapter(adapter).authorizedCallers(router)) {
            ERC4626Adapter(adapter).setAuthorizedCaller(router, true);
            console.log("    router authorized");
        }
        require(ERC4626Adapter(adapter).authorizedCallers(router), "router not authorized on adapter");

        return adapter;
    }

    /// @notice Registers a single vault as an instrument if it is not already registered.
    function _registerVault(string memory name, address vault, address adapter) internal {
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
            ERC4626Adapter(adapter).registerMarket(currency, vault);
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
