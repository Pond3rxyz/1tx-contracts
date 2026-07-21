// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {InstrumentRegistry} from "../../src/registries/InstrumentRegistry.sol";
import {InstrumentIdLib} from "../../src/libraries/InstrumentIdLib.sol";
import {AaveAdapter} from "../../src/adapters/AaveAdapter.sol";
import {CompoundAdapter} from "../../src/adapters/CompoundAdapter.sol";
import {MorphoAdapter} from "../../src/adapters/MorphoAdapter.sol";
import {EulerAdapter} from "../../src/adapters/EulerAdapter.sol";
import {FluidAdapter} from "../../src/adapters/FluidAdapter.sol";
import {ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {IERC4626} from "../../src/interfaces/IERC4626.sol";

import {RepointMigrator} from "./RepointMigrator.sol";

/// @title MigrateAdapters
/// @notice Swaps the deployed lending adapters for the `src/adapters` implementations on Base or
///         Arbitrum. Adapter deployment + market registration + router authorization run as normal
///         prep transactions (old adapters keep serving), then the whole instrument set is re-pointed
///         atomically in one transaction via {RepointMigrator}.
///
/// Dry run:
///   forge script script/migration/MigrateAdapters.s.sol:MigrateAdapters --rpc-url <base|arbitrum> \
///     --sender 0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73 -vvvv
///
/// Broadcast (signer MUST be the current registry/adapter owner):
///   forge script script/migration/MigrateAdapters.s.sol:MigrateAdapters --rpc-url <base|arbitrum> \
///     --account <keystore> --sender 0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73 --broadcast -vvvv
contract MigrateAdapters is Script {
    using stdJson for string;

    uint256 internal constant BASE = 8453;
    uint256 internal constant ARBITRUM = 42161;

    string internal json;
    string internal netPath;
    uint256 internal cid;

    InstrumentRegistry internal registry;
    address internal router;
    address internal owner;
    address internal aavePool;

    // Re-point batch, accumulated during the prep phase.
    bytes32[] internal ids;
    address[] internal execs;
    bytes32[] internal mids;
    address[] internal newAdapters;

    function run() external {
        cid = block.chainid;
        string memory net = _networkName(cid);
        json = vm.readFile("script/config/NetworkConfig.json");
        netPath = string.concat(".networks.", net);

        registry = InstrumentRegistry(_cfgAddr(".deployed.instrumentRegistry"));
        router = _cfgAddr(".deployed.swapDepositorRouter");
        aavePool = _cfgAddr(".protocols.aave.pool");
        owner = registry.owner();

        console.log("================================================");
        console.log("  Migrate adapters:", net);
        console.log("================================================");
        console.log("Registry:", address(registry));
        console.log("Owner:   ", owner);
        console.log("Router:  ", router);

        vm.startBroadcast();
        require(msg.sender == owner, "broadcaster is not the registry owner");

        // ---- Prep: deploy new proxy-backed adapters, register markets, authorize the router ----
        // Each adapter is wrapped in an ERC1967Proxy so its address is permanent: all FUTURE logic
        // changes ship via `upgradeToAndCall`.
        AaveAdapter aave =
            AaveAdapter(_proxy(address(new AaveAdapter()), abi.encodeCall(AaveAdapter.initialize, (aavePool, owner))));
        _registerAave(aave, _aaveSymbols(cid));
        aave.setAuthorizedCaller(router, true);
        console.log("New AaveAdapter:    ", address(aave));

        MorphoAdapter morpho =
            MorphoAdapter(_proxy(address(new MorphoAdapter()), abi.encodeCall(ERC4626Adapter.initialize, (owner))));
        _registerErc4626(address(morpho), "morpho", "vaults");
        morpho.setAuthorizedCaller(router, true);
        console.log("New MorphoAdapter:  ", address(morpho));

        EulerAdapter euler =
            EulerAdapter(_proxy(address(new EulerAdapter()), abi.encodeCall(ERC4626Adapter.initialize, (owner))));
        _registerErc4626(address(euler), "eulerEarn", "vaults");
        euler.setAuthorizedCaller(router, true);
        console.log("New EulerAdapter:   ", address(euler));

        if (cid == BASE) {
            CompoundAdapter comp = CompoundAdapter(
                _proxy(address(new CompoundAdapter()), abi.encodeCall(CompoundAdapter.initialize, (owner)))
            );
            _registerCompound(comp, "USDC", ".protocols.compound.usdcComet");
            _registerCompound(comp, "USDbC", ".protocols.compound.usdbcComet");
            comp.setAuthorizedCaller(router, true);
            console.log("New CompoundAdapter:", address(comp));

            FluidAdapter fluid =
                FluidAdapter(_proxy(address(new FluidAdapter()), abi.encodeCall(ERC4626Adapter.initialize, (owner))));
            _registerErc4626(address(fluid), "fluid", "fTokens");
            fluid.setAuthorizedCaller(router, true);
            console.log("New FluidAdapter:   ", address(fluid));
        }

        // Guard against silently missing an instrument.
        require(ids.length == _expectedCount(cid), "unexpected instrument count");

        // ---- Atomic re-point of the whole batch ----
        RepointMigrator migrator = new RepointMigrator(registry, owner);
        // Logged before ownership moves: if repoint() reverts, the registry is left owned by this
        // migrator and you need its address to call rescueRegistryOwnership().
        console.log("RepointMigrator:    ", address(migrator));
        registry.transferOwnership(address(migrator));
        migrator.repoint(ids, execs, mids, newAdapters);

        vm.stopBroadcast();

        // ---- Verify ----
        require(registry.owner() == owner, "registry ownership not returned");
        for (uint256 i; i < ids.length; ++i) {
            (address adapter,) = registry.instruments(ids[i]);
            require(adapter == newAdapters[i], "instrument not re-pointed");
        }
        console.log("\nRe-pointed instruments:", ids.length);
        console.log("Registry owner:", registry.owner());
        console.log("================================================");
    }

    /// @notice Deploys an ERC1967Proxy for `impl`, delegatecalling `initData` in the constructor.
    function _proxy(address impl, bytes memory initData) internal returns (address) {
        return address(new ERC1967Proxy(impl, initData));
    }

    // ============ Registration helpers ============

    /// @notice Registers Aave markets for the given token symbols and queues their re-points.
    /// @dev executionAddress for Aave instruments is the Aave pool; marketId = keccak256(currency).
    function _registerAave(AaveAdapter adapter, string[] memory symbols) internal {
        for (uint256 i; i < symbols.length; ++i) {
            address token = _cfgAddr(string.concat(".tokens.", symbols[i]));
            require(token != address(0), "aave token missing in config");
            Currency currency = Currency.wrap(token);

            adapter.registerMarket(currency);

            bytes32 marketId = keccak256(abi.encode(currency));
            _queue(aavePool, marketId, address(adapter));
        }
    }

    /// @notice Registers a single Compound market and queues its re-point.
    /// @dev executionAddress for Compound instruments is the Comet; marketId = keccak256(currency).
    function _registerCompound(CompoundAdapter adapter, string memory symbol, string memory cometKey) internal {
        address token = _cfgAddr(string.concat(".tokens.", symbol));
        address comet = _cfgAddr(cometKey);
        require(token != address(0) && comet != address(0), "compound market missing in config");
        Currency currency = Currency.wrap(token);

        adapter.registerMarket(currency, comet);

        bytes32 marketId = keccak256(abi.encode(currency));
        _queue(comet, marketId, address(adapter));
    }

    /// @notice Registers every ERC-4626 vault/fToken under a protocol list and queues their re-points.
    /// @dev executionAddress is the vault itself; marketId = bytes32(uint160(vault)).
    function _registerErc4626(address adapter, string memory protocolKey, string memory listKey) internal {
        string memory listPath = string.concat(netPath, ".protocols.", protocolKey, ".", listKey);
        if (!vm.keyExistsJson(json, listPath)) return;

        string[] memory names = vm.parseJsonKeys(json, listPath);
        for (uint256 i; i < names.length; ++i) {
            address vault = vm.parseJsonAddress(json, string.concat(listPath, ".", names[i]));
            Currency currency = Currency.wrap(IERC4626(vault).asset());

            ERC4626Adapter(adapter).registerMarket(currency, vault);

            bytes32 marketId = bytes32(uint256(uint160(vault)));
            _queue(vault, marketId, adapter);
        }
    }

    /// @notice Records an instrument re-point (computes its existing instrumentId).
    function _queue(address executionAddress, bytes32 marketId, address adapter) internal {
        bytes32 instrumentId = InstrumentIdLib.generateInstrumentId(cid, executionAddress, marketId);
        ids.push(instrumentId);
        execs.push(executionAddress);
        mids.push(marketId);
        newAdapters.push(adapter);
    }

    // ============ Chain-specific data ============

    function _networkName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == BASE) return "baseMainnet";
        if (chainId == ARBITRUM) return "arbitrumMainnet";
        revert("unsupported chain");
    }

    /// @notice Aave markets registered per chain (must match docs/deployments.md exactly).
    function _aaveSymbols(uint256 chainId) internal pure returns (string[] memory symbols) {
        if (chainId == BASE) {
            symbols = new string[](5);
            symbols[0] = "USDC";
            symbols[1] = "EURC";
            symbols[2] = "USDbC";
            symbols[3] = "GHO";
            symbols[4] = "cbBTC";
        } else {
            symbols = new string[](4);
            symbols[0] = "USDC";
            symbols[1] = "USDT";
            symbols[2] = "DAI";
            symbols[3] = "GHO";
        }
    }

    /// @notice Total registered instruments expected per chain (sanity guard).
    function _expectedCount(uint256 chainId) internal pure returns (uint256) {
        return chainId == BASE ? 18 : 14;
    }

    // ============ Config reader ============

    function _cfgAddr(string memory relPath) internal view returns (address) {
        return json.readAddress(string.concat(netPath, relPath));
    }
}
