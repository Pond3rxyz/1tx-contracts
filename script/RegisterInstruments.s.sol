// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {InstrumentRegistry} from "../src/registries/InstrumentRegistry.sol";
import {InstrumentIdLib} from "../src/libraries/InstrumentIdLib.sol";

import {ConfigReader, DeployedConfig} from "./utils/ConfigReader.sol";
import {ILendingAdapter} from "../src/interfaces/ILendingAdapter.sol";
import {IERC4626} from "../src/interfaces/IERC4626.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {AaveAdapter} from "../src/adapters/AaveAdapter.sol";
import {AdapterBaseUpgradeable} from "../src/adapters/base/AdapterBaseUpgradeable.sol";

/// @title RegisterInstruments
/// @notice Registers every market listed in NetworkConfig.json that is not yet registered,
///         deploying the protocol's adapter first if it does not exist. Idempotent: existing
///         adapters and instruments are skipped, only missing ones are created.
///
/// @dev **Two listing shapes, one script, one entry point.** The branch is picked from the config
///      block's own keys, so nothing has to be passed on the command line:
///
///      | keys in the protocol block | shape | adapter |
///      |---|---|---|
///      | `adapter` + `vaults`/`fTokens` | ERC-4626 | `ERC4626Adapter` |
///      | `pool` + `reserves` | Aave-shaped: Aave itself and any Aave **fork** | `AaveAdapter` |
///
///      Compound carries neither and drops out. Aave was out of scope until 2026-09-08 on the
///      grounds that it exposes no enumerable vault list — true, but it exposes an enumerable
///      *reserve* list in config, and that is enough. Adding the branch here rather than shipping
///      a second script is deliberate: an additive registration path that has to be chosen
///      correctly by whoever runs it is a path that gets run for one shape and forgotten for the
///      other.
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
///      The underlying asset is read on-chain from the vault, so config never tracks it.
///
///      **Adding an Aave fork is likewise a config change.** Add a block carrying `pool` and
///      `reserves`:
///
///      ```json
///      "neverland": {
///          "adapter":  { "key": "neverland", "name": "Neverland" },
///          "pool":     "0x80F0…D585",
///          "reserves": ["USDC", "AUSD"]
///      }
///      ```
///
///      The fork gets its **own** adapter proxy, carrying its own protocol identity via
///      {AaveAdapter-initializeNamed}, and {_resolveReserveAdapter} aborts rather than let a
///      fork's reserves land on Aave's adapter — see its docstring for why that would silently
///      repoint Aave's own market.
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
    using stdJson for string;

    /// @dev The two names a vault list goes by in config.
    string[2] internal LIST_KEYS = ["vaults", "fTokens"];

    InstrumentRegistry public registry;
    address public router;

    string internal config;
    string internal netPath;

    uint256 public registered;
    uint256 public skipped;
    uint256 public adaptersDeployed;
    /// @notice Reserve symbols this chain's `tokens` map or pool did not answer for.
    uint256 public unresolved;

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

        // Every protocol in config is considered; _registerProtocol picks the branch from the
        // block's own keys and drops anything that is neither shape (Compound).
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
        console.log("  Skipped (exists):      ", skipped);
        console.log("  Skipped (unresolved):  ", unresolved);
        console.log("================================================\n");
    }

    /// @notice Resolves a protocol's adapter (deploying it if absent) and registers its markets.
    /// @dev Two listing shapes, told apart by which keys the config block carries:
    ///        - `pool` + `reserves`  -> Aave-shaped (Aave itself, and any Aave *fork*)
    ///        - `adapter` + `vaults`/`fTokens` -> ERC-4626
    ///      Compound carries neither and drops out. The reserve branch is checked first because
    ///      `aave` predates the `adapter` block and has none.
    function _registerProtocol(string memory protocolKey) internal {
        string memory protoPath = string.concat(netPath, ".protocols.", protocolKey);
        if (!vm.keyExistsJson(config, protoPath)) return;

        if (_isReserveShaped(config, protoPath)) {
            _registerReserves(protocolKey, protoPath);
            return;
        }

        // No `adapter` block and no reserve list means this is not a listing we can register.
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

        _authorizeRouter(adapter);

        return adapter;
    }

    /// @notice Authorizes the router on an adapter if it is not already, then asserts it.
    /// @dev Idempotent, and asserted rather than assumed: an adapter the router cannot call is a
    ///      market where deposits succeed and every withdrawal reverts `UnauthorizedCaller`.
    ///      Typed against the shared base, so it serves both listing shapes.
    function _authorizeRouter(address adapter) internal {
        AdapterBaseUpgradeable a = AdapterBaseUpgradeable(adapter);
        if (!a.authorizedCallers(router)) {
            a.setAuthorizedCaller(router, true);
            console.log("    router authorized");
        }
        require(a.authorizedCallers(router), "router not authorized on adapter");
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

    // ============================================
    // Aave-shaped listings
    // ============================================

    /// @notice Whether a protocol block is an Aave-shaped listing: **both** `pool` and `reserves`.
    /// @dev `public` and taking the JSON as an argument so the rule is unit-testable against a
    ///      fixture string, without the filesystem and without depending on what the real config
    ///      happens to contain today.
    function _isReserveShaped(string memory json, string memory protoPath) public view returns (bool) {
        return vm.keyExistsJson(json, string.concat(protoPath, ".pool"))
            && vm.keyExistsJson(json, string.concat(protoPath, ".reserves"));
    }

    /// @notice The protocol keys under `netPath_` that {_isReserveShaped} selects, in config order.
    function reserveShapedProtocols(string memory json, string memory netPath_)
        public
        view
        returns (string[] memory selected)
    {
        string memory protocolsPath = string.concat(netPath_, ".protocols");
        if (!vm.keyExistsJson(json, protocolsPath)) return new string[](0);

        string[] memory all = vm.parseJsonKeys(json, protocolsPath);
        string[] memory buffer = new string[](all.length);
        uint256 count;

        for (uint256 i = 0; i < all.length; i++) {
            if (_isReserveShaped(json, string.concat(protocolsPath, ".", all[i]))) buffer[count++] = all[i];
        }

        selected = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            selected[i] = buffer[i];
        }
    }

    /// @notice Registers every reserve a protocol lists that is not yet registered.
    /// @dev This is what makes an Aave reserve addable to a chain that is already live. Before it,
    ///      the only code that registered one was `Deploy._registerAaveMarkets`, step 3 of an
    ///      eight-step `run()` that also deploys the registries, the adapters, the router and the
    ///      whole CCTP mesh — so Monad's Aave GHO reserve could be written into config and never
    ///      registered. {ConfigReader-getAaveReserveSymbols} said so in its own docstring: *"a
    ///      reserve missed on this run has no additive script to add it later"*.
    ///
    ///      It is generic over Aave-shaped protocols, so one branch covers Aave itself and every
    ///      Aave **fork** — Neverland on Monad — and the next fork needs no Solidity.
    function _registerReserves(string memory protocolKey, string memory protoPath) internal {
        string[] memory symbols = config.readStringArray(string.concat(protoPath, ".reserves"));
        if (symbols.length == 0) return;

        address pool = vm.parseJsonAddress(config, string.concat(protoPath, ".pool"));
        require(pool != address(0), string.concat("zero pool address for protocol: ", protocolKey));

        console.log(string.concat("\n--- ", protocolKey, " ---"));
        console.log("  pool:", pool);

        address adapter = _resolveReserveAdapter(protocolKey, protoPath, pool);

        for (uint256 i = 0; i < symbols.length; i++) {
            _registerReserve(symbols[i], pool, adapter);
        }
    }

    /// @notice Reads the deployed adapter for an Aave-shaped protocol, deploying it when absent.
    /// @dev The two aborts here are why a fork cannot quietly land on Aave's adapter.
    ///      `AaveAdapter` keys markets by `keccak256(abi.encode(currency))` — *no pool in the
    ///      preimage* — so Aave USDC and Neverland USDC share a `marketId`. That is safe only
    ///      because each pool gets its own proxy and `markets` is per-proxy storage; register a
    ///      fork's reserves on Aave's adapter and you silently repoint Aave's own market. At the
    ///      registry level there is no collision at all: `generateInstrumentId` hashes
    ///      `(chainid, pool, marketId)` and the two pools differ.
    function _resolveReserveAdapter(string memory protocolKey, string memory protoPath, address pool)
        internal
        returns (address adapter)
    {
        string memory adapterPath = string.concat(protoPath, ".adapter");
        bool hasBlock = vm.keyExistsJson(config, adapterPath);

        // `aave` predates the `adapter` block and has none: its deployed key is the protocol key,
        // and its identity is {AaveAdapter-_adapterName}'s historical fallback.
        string memory adapterKey = (hasBlock && vm.keyExistsJson(config, string.concat(adapterPath, ".key")))
            ? vm.parseJsonString(config, string.concat(adapterPath, ".key"))
            : protocolKey;
        string memory adapterName = (hasBlock && vm.keyExistsJson(config, string.concat(adapterPath, ".name")))
            ? vm.parseJsonString(config, string.concat(adapterPath, ".name"))
            : "";

        string memory deployedPath = string.concat(netPath, ".deployed.adapters.", adapterKey);
        adapter = vm.keyExistsJson(config, deployedPath) ? vm.parseJsonAddress(config, deployedPath) : address(0);

        if (adapter != address(0)) {
            console.log("  adapter (from config):", adapter);
        } else {
            require(
                bytes(adapterName).length > 0,
                string.concat("no deployed adapter and no `adapter.name` to deploy one under: ", protocolKey)
            );

            AaveAdapter impl = new AaveAdapter();
            adapter = address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(AaveAdapter.initializeNamed, (pool, msg.sender, adapterName))
                )
            );
            adaptersDeployed++;

            console.log(string.concat("  DEPLOYED adapter '", adapterName, "'"));
            console.log("    implementation:", address(impl));
            console.log("    proxy:         ", adapter);
            console.log("    -> write this proxy into NetworkConfig.json deployed.adapters and docs/deployments.md");
        }

        // Not repointable: `AAVE_POOL` is set once at init, so this aborts rather than fixes.
        address wiredPool = address(AaveAdapter(adapter).AAVE_POOL());
        if (wiredPool != pool) {
            console.log(string.concat("\n  POOL MISMATCH on ", protocolKey));
            console.log("    adapter AAVE_POOL():", wiredPool);
            console.log("    config pool:        ", pool);
            revert("adapter points at a different pool than its config block; fix config or deploy a new proxy");
        }

        // And the same check on the identity it reports, which is what `max_weight_per_protocol`
        // budgets against downstream. Skipped when config names no adapter — `aave`'s case, where
        // the reported name is the historical fallback.
        if (bytes(adapterName).length > 0) {
            string memory reported = AaveAdapter(adapter).getAdapterMetadata().name;
            if (keccak256(bytes(reported)) != keccak256(bytes(adapterName))) {
                console.log(string.concat("\n  IDENTITY MISMATCH on ", protocolKey));
                console.log(string.concat("    adapter reports: ", reported));
                console.log(string.concat("    config names:    ", adapterName));
                revert("adapter reports a different protocol name than config; it would be booked to the wrong budget");
            }
        }

        _authorizeRouter(adapter);
    }

    /// @notice Registers a single reserve as an instrument if it is not already registered.
    function _registerReserve(string memory symbol, address pool, address adapter) internal {
        address token = getTokenAddressBySymbol(_networkName(), symbol);
        if (token == address(0)) {
            // Logged rather than silent: a reserve list is written by hand, so a symbol it names
            // that the token map does not is an operator slip.
            console.log(string.concat("  SKIP (token not in `tokens` map): ", symbol));
            unresolved++;
            return;
        }

        // The on-chain filter that makes an over-broad `reserves` list safe. A symbol this pool
        // does not list is not an error — one array covers a protocol across chains that list
        // different assets.
        address aToken = IAavePool(pool).getReserveData(token).aTokenAddress;
        if (aToken == address(0)) {
            console.log(string.concat("  SKIP (not a reserve on this pool): ", symbol));
            unresolved++;
            return;
        }

        Currency currency = Currency.wrap(token);
        bytes32 marketId = keccak256(abi.encode(currency));
        bytes32 instrumentId = InstrumentIdLib.generateInstrumentId(block.chainid, pool, marketId);
        (address existingAdapter,) = registry.instruments(instrumentId);

        if (existingAdapter == adapter) {
            console.log(string.concat("  SKIP (exists): ", symbol));
            skipped++;
            return;
        }

        // Checked before anything is written, so a run that is going to abort does not first
        // mutate the adapter it was about to refuse to use. `registerInstrument` reverts
        // `InstrumentAlreadyRegistered` on this anyway; aborting here says *why*.
        if (existingAdapter != address(0)) {
            console.log(string.concat("\n  ADAPTER MISMATCH on ", symbol));
            console.log("    registered adapter:", existingAdapter);
            console.log("    config     adapter:", adapter);
            revert("instrument is registered under a different adapter; unregister it deliberately first");
        }

        if (!ILendingAdapter(adapter).hasMarket(marketId)) {
            AaveAdapter(adapter).registerMarket(currency);
        }

        registry.registerInstrument(pool, marketId, adapter);
        registered++;

        console.log(string.concat("  Registered: ", symbol));
        console.log("    token: ", token);
        console.log("    aToken:", aToken);
        console.log("    instrumentId:", vm.toString(instrumentId));
    }

    function _networkName() internal view returns (string memory) {
        return detectNetworkFromChainId(block.chainid);
    }
}
