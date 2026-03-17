// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {SwapDepositRouter} from "../src/SwapDepositRouter.sol";
import {CCTPBridge} from "../src/CCTPBridge.sol";
import {CCTPReceiver} from "../src/CCTPReceiver.sol";
import {InstrumentRegistry} from "../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../src/registries/SwapPoolRegistry.sol";
import {AaveAdapter} from "../src/adapters/AaveAdapter.sol";
import {CompoundAdapter} from "../src/adapters/CompoundAdapter.sol";
import {MorphoAdapter} from "../src/adapters/MorphoAdapter.sol";
import {EulerAdapter} from "../src/adapters/EulerAdapter.sol";
import {FluidAdapter} from "../src/adapters/FluidAdapter.sol";
import {InstrumentIdLib} from "../src/libraries/InstrumentIdLib.sol";
import {IAavePool} from "../src/interfaces/IAavePool.sol";

import {
    ConfigReader,
    NetworkConfig,
    DeployedConfig,
    CCTPConfig,
    CCTPDestination,
    SwapPoolConfig
} from "./utils/ConfigReader.sol";

/// @title Deploy
/// @notice Universal deployment script for the 1tx protocol
/// @dev Deploys all contracts, registers instruments, configures CCTP — fully self-contained
///
/// Usage:
///   FOUNDRY_PROFILE=deploy forge script script/Deploy.s.sol:Deploy \
///     --rpc-url <network> --account <keystore> --broadcast -vvvv
///
/// Deploys:
///   1. Core: InstrumentRegistry, SwapPoolRegistry
///   2. Adapters: Aave, Compound, Morpho, Euler, Fluid (if configured)
///   3. Instruments: Registers all markets in InstrumentRegistry
///   4. Swap Pools: Registers bidirectional swap pools
///   5. Router: SwapDepositRouter (UUPS proxy)
///   6. CCTP: CCTPBridge + CCTPReceiver (if configured)
///   7. Wiring: Router ↔ Bridge ↔ Receiver cross-references
contract Deploy is ConfigReader {
    using CurrencyLibrary for Currency;

    // Configuration
    NetworkConfig public config;
    string public networkName;

    // CCTP config stored as individual fields (dynamic arrays can't be copied memory->storage)
    address public cctpTokenMessenger;
    address public cctpMessageTransmitter;
    uint32 public cctpDomain;
    CCTPDestination[] public cctpDestinations;

    // Deployed contracts
    InstrumentRegistry public registry;
    SwapPoolRegistry public swapPoolRegistry;
    AaveAdapter public aaveAdapter;
    CompoundAdapter public compoundAdapter;
    MorphoAdapter public morphoAdapter;
    EulerAdapter public eulerAdapter;
    FluidAdapter public fluidAdapter;
    SwapDepositRouter public router;
    CCTPBridge public bridge;
    CCTPReceiver public receiver;

    function run() external {
        _loadConfiguration();
        _validateNetwork();

        address deployer = msg.sender;
        _logDeploymentStart(deployer);

        vm.startBroadcast();

        // Core
        _deployCore(deployer);

        // Adapters
        _deployAave(deployer);
        _deployCompound(deployer);
        _deployMorpho(deployer);
        _deployEuler(deployer);
        _deployFluid(deployer);

        // Register instruments
        _registerAaveMarkets();
        _registerCompoundMarkets();
        _registerMorphoVaults();
        _registerEulerVaults();
        _registerFluidFTokens();

        // Swap pools
        _registerSwapPools();

        // Router
        _deployRouter(deployer);

        // Authorize router on adapters for withdrawals
        _authorizeRouterForWithdrawals();

        // CCTP
        _deployCCTP(deployer);
        _configureCCTP(deployer);

        vm.stopBroadcast();

        _logDeploymentSummary(deployer);
    }

    // ============================================
    // Configuration & Validation
    // ============================================

    function _loadConfiguration() internal {
        networkName = detectNetworkFromChainId(block.chainid);
        require(isNetworkSupported(networkName), "Unsupported network");
        NetworkConfig memory memoryConfig = getNetworkConfig(networkName);
        config.chainId = memoryConfig.chainId;
        config.explorer = memoryConfig.explorer;
        config.uniswapV4 = memoryConfig.uniswapV4;
        config.tokens = memoryConfig.tokens;
        config.protocols = memoryConfig.protocols;

        // Manual array copy (via_ir = false doesn't support memory->storage struct array copy)
        delete config.swapPools;
        for (uint256 i = 0; i < memoryConfig.swapPools.length; i++) {
            config.swapPools.push(memoryConfig.swapPools[i]);
        }

        CCTPConfig memory cctp = getCCTPConfig(networkName);
        cctpTokenMessenger = cctp.tokenMessenger;
        cctpMessageTransmitter = cctp.messageTransmitter;
        cctpDomain = cctp.domain;
        delete cctpDestinations;
        for (uint256 i = 0; i < cctp.destinations.length; i++) {
            cctpDestinations.push(cctp.destinations[i]);
        }
    }

    function _validateNetwork() internal view {
        require(config.chainId == block.chainid, "Chain ID mismatch");
        require(config.uniswapV4.poolManager != address(0), "PoolManager not configured");
        require(config.tokens.USDC != address(0), "USDC not configured");
    }

    // ============================================
    // Core Deployment
    // ============================================

    function _deployCore(address deployer) internal {
        console.log("\n[1/8] Deploying Core Contracts");
        console.log("-----------------------------------------------");

        // InstrumentRegistry
        InstrumentRegistry registryImpl = new InstrumentRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl), abi.encodeWithSelector(InstrumentRegistry.initialize.selector, deployer)
        );
        registry = InstrumentRegistry(address(registryProxy));
        console.log("  InstrumentRegistry (proxy):", address(registry));
        console.log("  InstrumentRegistry (impl):", address(registryImpl));

        // SwapPoolRegistry
        SwapPoolRegistry swapPoolImpl = new SwapPoolRegistry();
        ERC1967Proxy swapPoolProxy = new ERC1967Proxy(
            address(swapPoolImpl), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, deployer)
        );
        swapPoolRegistry = SwapPoolRegistry(address(swapPoolProxy));
        console.log("  SwapPoolRegistry (proxy):", address(swapPoolRegistry));
        console.log("  SwapPoolRegistry (impl):", address(swapPoolImpl));
    }

    // ============================================
    // Adapter Deployment
    // ============================================

    function _deployAave(address deployer) internal {
        if (config.protocols.aave.pool == address(0)) return;

        console.log("\n[2/8] Deploying Aave Adapter");
        console.log("-----------------------------------------------");
        aaveAdapter = new AaveAdapter(config.protocols.aave.pool, deployer);
        console.log("  AaveAdapter:", address(aaveAdapter));
        console.log("  Aave Pool:", config.protocols.aave.pool);
    }

    function _deployCompound(address deployer) internal {
        if (config.protocols.compound.configurator == address(0)) return;

        console.log("\n[2/8] Deploying Compound Adapter");
        console.log("-----------------------------------------------");
        compoundAdapter = new CompoundAdapter(deployer);
        console.log("  CompoundAdapter:", address(compoundAdapter));
    }

    function _deployMorpho(address deployer) internal {
        bool hasVaults = config.protocols.morpho.vaults.steakhouseUSDC != address(0)
            || config.protocols.morpho.vaults.sparkUSDC != address(0)
            || config.protocols.morpho.vaults.gauntletUSDCPrime != address(0)
            || config.protocols.morpho.vaults.steakhousePrimeUSDC != address(0)
            || config.protocols.morpho.vaults.re7EUSD != address(0)
            || config.protocols.morpho.vaults.clearstarUSDC != address(0)
            || config.protocols.morpho.vaults.mevFrontierUSDC != address(0)
            || config.protocols.morpho.vaults.clearstarHighYieldUSDC != address(0)
            || config.protocols.morpho.vaults.kpkUSDCYield != address(0)
            || config.protocols.morpho.vaults.yearnDegenUSDC != address(0)
            || config.protocols.morpho.vaults.hyperithmUSDC != address(0)
            || config.protocols.morpho.vaults.clearstarUSDCReactor != address(0)
            || config.protocols.morpho.vaults.gauntletUSDCCore != address(0)
            || config.protocols.morpho.vaults.steakhouseHighYieldUSDC != address(0)
            || config.protocols.morpho.vaults.gauntletUSDCC != address(0);

        if (!hasVaults) return;

        console.log("\n[2/8] Deploying Morpho Adapter");
        console.log("-----------------------------------------------");
        morphoAdapter = new MorphoAdapter(deployer);
        console.log("  MorphoAdapter:", address(morphoAdapter));
    }

    function _deployEuler(address deployer) internal {
        if (config.protocols.eulerEarn.vaults.eeUSDC == address(0)) return;

        console.log("\n[2/8] Deploying Euler Earn Adapter");
        console.log("-----------------------------------------------");
        eulerAdapter = new EulerAdapter(deployer);
        console.log("  EulerAdapter:", address(eulerAdapter));
    }

    function _deployFluid(address deployer) internal {
        if (config.protocols.fluid.liquidity == address(0)) return;

        console.log("\n[2/8] Deploying Fluid Adapter");
        console.log("-----------------------------------------------");
        fluidAdapter = new FluidAdapter(deployer);
        console.log("  FluidAdapter:", address(fluidAdapter));
    }

    // ============================================
    // Instrument Registration
    // ============================================

    function _registerAaveMarkets() internal {
        if (address(aaveAdapter) == address(0)) return;

        console.log("\n[3/8] Registering Aave Markets");
        console.log("-----------------------------------------------");

        _registerAaveStablecoin("USDC", config.tokens.USDC);
        _registerAaveStablecoin("USDT", config.tokens.USDT);
        _registerAaveStablecoin("DAI", config.tokens.DAI);
        _registerAaveStablecoin("EURC", config.tokens.EURC);
        _registerAaveStablecoin("USDbC", config.tokens.USDbC);
        _registerAaveStablecoin("GHO", config.tokens.GHO);
        _registerAaveStablecoin("USDS", config.tokens.USDS);
        _registerAaveStablecoin("cbBTC", config.tokens.cbBTC);
    }

    function _registerAaveStablecoin(string memory symbol, address token) internal {
        if (token == address(0)) return;

        // Check if token is a valid Aave reserve
        IAavePool aavePool = IAavePool(config.protocols.aave.pool);
        IAavePool.ReserveData memory reserveData = aavePool.getReserveData(token);
        if (reserveData.aTokenAddress == address(0)) return;

        Currency currency = Currency.wrap(token);
        aaveAdapter.registerMarket(currency);

        bytes32 marketId = keccak256(abi.encode(currency));
        registry.registerInstrument(config.protocols.aave.pool, marketId, address(aaveAdapter));

        bytes32 instrumentId = _generateInstrumentId(block.chainid, config.protocols.aave.pool, marketId);
        console.log("  Aave", symbol);
        console.log("    instrumentId:", vm.toString(instrumentId));
    }

    function _registerCompoundMarkets() internal {
        if (address(compoundAdapter) == address(0)) return;

        console.log("\n[3/8] Registering Compound Markets");
        console.log("-----------------------------------------------");

        if (config.tokens.USDC != address(0) && config.protocols.compound.usdcComet != address(0)) {
            _registerCompoundMarket("USDC", config.tokens.USDC, config.protocols.compound.usdcComet);
        }
        if (config.tokens.USDbC != address(0) && config.protocols.compound.usdbcComet != address(0)) {
            _registerCompoundMarket("USDbC", config.tokens.USDbC, config.protocols.compound.usdbcComet);
        }
        if (config.tokens.USDS != address(0) && config.protocols.compound.usdsComet != address(0)) {
            _registerCompoundMarket("USDS", config.tokens.USDS, config.protocols.compound.usdsComet);
        }
    }

    function _registerCompoundMarket(string memory symbol, address token, address cometAddress) internal {
        Currency currency = Currency.wrap(token);
        compoundAdapter.registerMarket(currency, cometAddress);

        bytes32 marketId = keccak256(abi.encode(currency));
        registry.registerInstrument(cometAddress, marketId, address(compoundAdapter));

        bytes32 instrumentId = _generateInstrumentId(block.chainid, cometAddress, marketId);
        console.log("  Compound", symbol, "Comet:", cometAddress);
        console.log("    instrumentId:", vm.toString(instrumentId));
    }

    function _registerMorphoVaults() internal {
        if (address(morphoAdapter) == address(0)) return;

        console.log("\n[3/8] Registering Morpho Vaults");
        console.log("-----------------------------------------------");

        // Base vaults
        _registerMorphoVault("Steakhouse USDC", config.tokens.USDC, config.protocols.morpho.vaults.steakhouseUSDC);
        _registerMorphoVault("Spark USDC", config.tokens.USDC, config.protocols.morpho.vaults.sparkUSDC);
        _registerMorphoVault(
            "Gauntlet USDC Prime", config.tokens.USDC, config.protocols.morpho.vaults.gauntletUSDCPrime
        );
        _registerMorphoVault(
            "Steakhouse Prime USDC", config.tokens.USDC, config.protocols.morpho.vaults.steakhousePrimeUSDC
        );
        _registerMorphoVault("Re7 eUSD", config.tokens.eUSD, config.protocols.morpho.vaults.re7EUSD);
        _registerMorphoVault("Clearstar USDC", config.tokens.USDC, config.protocols.morpho.vaults.clearstarUSDC);
        _registerMorphoVault("MEV Frontier USDC", config.tokens.USDC, config.protocols.morpho.vaults.mevFrontierUSDC);

        // Arbitrum vaults
        _registerMorphoVault(
            "Clearstar High Yield USDC", config.tokens.USDC, config.protocols.morpho.vaults.clearstarHighYieldUSDC
        );
        _registerMorphoVault("KPK USDC Yield", config.tokens.USDC, config.protocols.morpho.vaults.kpkUSDCYield);
        _registerMorphoVault("Yearn Degen USDC", config.tokens.USDC, config.protocols.morpho.vaults.yearnDegenUSDC);
        _registerMorphoVault("Hyperithm USDC", config.tokens.USDC, config.protocols.morpho.vaults.hyperithmUSDC);
        _registerMorphoVault(
            "Clearstar USDC Reactor", config.tokens.USDC, config.protocols.morpho.vaults.clearstarUSDCReactor
        );
        _registerMorphoVault("Gauntlet USDC Core", config.tokens.USDC, config.protocols.morpho.vaults.gauntletUSDCCore);
        _registerMorphoVault(
            "Steakhouse High Yield USDC", config.tokens.USDC, config.protocols.morpho.vaults.steakhouseHighYieldUSDC
        );

        // Unichain vaults
        _registerMorphoVault("Gauntlet USDC-C", config.tokens.USDC, config.protocols.morpho.vaults.gauntletUSDCC);
    }

    function _registerMorphoVault(string memory name, address asset, address vault) internal {
        if (asset == address(0) || vault == address(0)) return;

        Currency currency = Currency.wrap(asset);
        morphoAdapter.registerVault(currency, vault);

        bytes32 marketId = bytes32(uint256(uint160(vault)));
        registry.registerInstrument(vault, marketId, address(morphoAdapter));

        bytes32 instrumentId = _generateInstrumentId(block.chainid, vault, marketId);
        console.log("  Morpho", name);
        console.log("    vault:", vault);
        console.log("    instrumentId:", vm.toString(instrumentId));
    }

    function _registerEulerVaults() internal {
        if (address(eulerAdapter) == address(0)) return;

        console.log("\n[3/8] Registering Euler Earn Vaults");
        console.log("-----------------------------------------------");

        _registerEulerVault("eeUSDC", config.tokens.USDC, config.protocols.eulerEarn.vaults.eeUSDC);
    }

    function _registerEulerVault(string memory name, address asset, address vault) internal {
        if (asset == address(0) || vault == address(0)) return;

        Currency currency = Currency.wrap(asset);
        eulerAdapter.registerVault(currency, vault);

        bytes32 marketId = bytes32(uint256(uint160(vault)));
        registry.registerInstrument(vault, marketId, address(eulerAdapter));

        bytes32 instrumentId = _generateInstrumentId(block.chainid, vault, marketId);
        console.log("  Euler", name);
        console.log("    vault:", vault);
        console.log("    instrumentId:", vm.toString(instrumentId));
    }

    function _registerFluidFTokens() internal {
        if (address(fluidAdapter) == address(0)) return;

        console.log("\n[3/8] Registering Fluid fTokens");
        console.log("-----------------------------------------------");

        _registerFluidFToken("fUSDC", config.tokens.USDC, config.protocols.fluid.fTokens.fUSDC);
        _registerFluidFToken("fEURC", config.tokens.EURC, config.protocols.fluid.fTokens.fEURC);
        _registerFluidFToken("fGHO", config.tokens.GHO, config.protocols.fluid.fTokens.fGHO);
    }

    function _registerFluidFToken(string memory name, address asset, address fToken) internal {
        if (asset == address(0) || fToken == address(0)) return;

        Currency currency = Currency.wrap(asset);
        fluidAdapter.registerFToken(currency, fToken);

        bytes32 marketId = bytes32(uint256(uint160(fToken)));
        registry.registerInstrument(fToken, marketId, address(fluidAdapter));

        bytes32 instrumentId = _generateInstrumentId(block.chainid, fToken, marketId);
        console.log("  Fluid", name);
        console.log("    fToken:", fToken);
        console.log("    instrumentId:", vm.toString(instrumentId));
    }

    // ============================================
    // Swap Pools
    // ============================================

    function _registerSwapPools() internal {
        console.log("\n[4/8] Registering Swap Pools");
        console.log("-----------------------------------------------");

        if (config.swapPools.length == 0) {
            console.log("  No swap pools configured");
            return;
        }

        for (uint256 i = 0; i < config.swapPools.length; i++) {
            SwapPoolConfig memory poolConfig = config.swapPools[i];

            address token0 = _getTokenAddress(poolConfig.tokenIn);
            address token1 = _getTokenAddress(poolConfig.tokenOut);

            if (token0 == address(0) || token1 == address(0)) {
                console.log(
                    string.concat("  SKIPPED ", poolConfig.tokenIn, "/", poolConfig.tokenOut, " (token not found)")
                );
                continue;
            }

            // Ensure currency0 < currency1 for Uniswap V4
            (Currency currency0, Currency currency1) = token0 < token1
                ? (Currency.wrap(token0), Currency.wrap(token1))
                : (Currency.wrap(token1), Currency.wrap(token0));

            PoolKey memory key = PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: poolConfig.fee,
                tickSpacing: poolConfig.tickSpacing,
                hooks: IHooks(poolConfig.hooks)
            });

            Currency inputCurrency = Currency.wrap(token0);
            Currency outputCurrency = Currency.wrap(token1);

            swapPoolRegistry.registerDefaultSwapPool(inputCurrency, outputCurrency, key);
            swapPoolRegistry.registerDefaultSwapPool(outputCurrency, inputCurrency, key);

            console.log(
                string.concat("  Registered: ", poolConfig.tokenIn, " / ", poolConfig.tokenOut, " (bidirectional)")
            );
        }
    }

    function _getTokenAddress(string memory symbol) internal view returns (address) {
        if (keccak256(bytes(symbol)) == keccak256(bytes("USDC"))) return config.tokens.USDC;
        if (keccak256(bytes(symbol)) == keccak256(bytes("USDT"))) return config.tokens.USDT;
        if (keccak256(bytes(symbol)) == keccak256(bytes("DAI"))) return config.tokens.DAI;
        if (keccak256(bytes(symbol)) == keccak256(bytes("EURC"))) return config.tokens.EURC;
        if (keccak256(bytes(symbol)) == keccak256(bytes("USDbC"))) return config.tokens.USDbC;
        if (keccak256(bytes(symbol)) == keccak256(bytes("GHO"))) return config.tokens.GHO;
        if (keccak256(bytes(symbol)) == keccak256(bytes("USDS"))) return config.tokens.USDS;
        if (keccak256(bytes(symbol)) == keccak256(bytes("cbBTC"))) return config.tokens.cbBTC;
        if (keccak256(bytes(symbol)) == keccak256(bytes("WETH"))) return config.tokens.WETH;
        if (keccak256(bytes(symbol)) == keccak256(bytes("eUSD"))) return config.tokens.eUSD;
        return address(0);
    }

    // ============================================
    // Router
    // ============================================

    function _deployRouter(address deployer) internal {
        console.log("\n[5/8] Deploying SwapDepositRouter");
        console.log("-----------------------------------------------");

        SwapDepositRouter routerImpl = new SwapDepositRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeWithSelector(
                SwapDepositRouter.initialize.selector,
                deployer,
                IPoolManager(config.uniswapV4.poolManager),
                registry,
                swapPoolRegistry,
                Currency.wrap(config.tokens.USDC)
            )
        );
        router = SwapDepositRouter(address(routerProxy));

        console.log("  SwapDepositRouter (proxy):", address(router));
        console.log("  SwapDepositRouter (impl):", address(routerImpl));
    }

    function _authorizeRouterForWithdrawals() internal {
        console.log("\n[5.5/8] Authorizing Router for Withdrawals");
        console.log("-----------------------------------------------");

        if (address(aaveAdapter) != address(0)) {
            aaveAdapter.addAuthorizedCaller(address(router));
            console.log("  Router authorized on AaveAdapter");
        }
        if (address(compoundAdapter) != address(0)) {
            compoundAdapter.addAuthorizedCaller(address(router));
            console.log("  Router authorized on CompoundAdapter");
        }
        if (address(morphoAdapter) != address(0)) {
            morphoAdapter.addAuthorizedCaller(address(router));
            console.log("  Router authorized on MorphoAdapter");
        }
        if (address(eulerAdapter) != address(0)) {
            eulerAdapter.addAuthorizedCaller(address(router));
            console.log("  Router authorized on EulerAdapter");
        }
        if (address(fluidAdapter) != address(0)) {
            fluidAdapter.addAuthorizedCaller(address(router));
            console.log("  Router authorized on FluidAdapter");
        }
    }

    // ============================================
    // CCTP Deployment & Configuration
    // ============================================

    function _deployCCTP(address deployer) internal {
        console.log("\n[6/8] Deploying CCTP Contracts");
        console.log("-----------------------------------------------");

        // CCTPBridge
        if (cctpTokenMessenger != address(0)) {
            CCTPBridge bridgeImpl = new CCTPBridge();
            ERC1967Proxy bridgeProxy = new ERC1967Proxy(
                address(bridgeImpl), abi.encodeWithSelector(CCTPBridge.initialize.selector, deployer)
            );
            bridge = CCTPBridge(address(bridgeProxy));
            console.log("  CCTPBridge (proxy):", address(bridge));
            console.log("  CCTPBridge (impl):", address(bridgeImpl));
        } else {
            console.log("  CCTPBridge: SKIPPED (no tokenMessenger configured)");
        }

        // CCTPReceiver
        if (cctpMessageTransmitter != address(0)) {
            CCTPReceiver receiverImpl = new CCTPReceiver();
            ERC1967Proxy receiverProxy = new ERC1967Proxy(
                address(receiverImpl),
                abi.encodeWithSelector(
                    CCTPReceiver.initialize.selector,
                    deployer,
                    address(router),
                    config.tokens.USDC,
                    cctpMessageTransmitter
                )
            );
            receiver = CCTPReceiver(address(receiverProxy));
            console.log("  CCTPReceiver (proxy):", address(receiver));
            console.log("  CCTPReceiver (impl):", address(receiverImpl));
        } else {
            console.log("  CCTPReceiver: SKIPPED (no messageTransmitter configured)");
        }
    }

    function _configureCCTP(address) internal {
        if (address(bridge) == address(0) && address(receiver) == address(0)) return;

        console.log("\n[7/8] Configuring CCTP (same-chain wiring only)");
        console.log("-----------------------------------------------");

        // Wire router -> bridge + receiver (same-chain references)
        if (address(bridge) != address(0)) {
            router.setCCTPBridge(address(bridge));
            console.log("  Router.cctpBridge:", address(bridge));
        }
        if (address(receiver) != address(0)) {
            router.setCCTPReceiver(address(receiver));
            console.log("  Router.cctpReceiver:", address(receiver));
        }

        // Configure bridge basics (tokenMessenger, authorized caller, destination domains)
        if (address(bridge) != address(0)) {
            bridge.setTokenMessenger(cctpTokenMessenger);
            console.log("  Bridge.tokenMessenger:", cctpTokenMessenger);

            bridge.setAuthorizedCaller(address(router), true);
            console.log("  Bridge: router authorized as caller");

            // Register destination domains (static CCTP domain IDs — always known)
            for (uint256 i = 0; i < cctpDestinations.length; i++) {
                CCTPDestination memory dest = cctpDestinations[i];
                bridge.setDestinationDomain(dest.chainId, dest.domain);
                console.log("  Bridge destination:", dest.name);
                console.log("    chainId:", uint256(dest.chainId), "-> domain:", uint256(dest.domain));
            }

            // NOTE: mintRecipient + destinationCaller are NOT set here.
            // Those point to CCTPReceiver on the OTHER chain, which may not exist yet.
            // Run ConfigureCCTP.s.sol after deploying on both chains to complete wiring.
            console.log("");
            console.log("  >> Cross-chain wiring DEFERRED <<");
            console.log("  After deploying on all chains, run ConfigureCCTP to set:");
            console.log("    - bridge.setDestinationMintRecipient(chainId, receiver)");
            console.log("    - bridge.setDestinationCaller(chainId, receiver)");
        }
    }

    // ============================================
    // Logging
    // ============================================

    function _logDeploymentStart(address deployer) internal view {
        console.log("\n================================================");
        console.log("  1tx Protocol - Universal Deployment");
        console.log("================================================");
        console.log("Network:       ", networkName);
        console.log("Chain ID:      ", config.chainId);
        console.log("Deployer:      ", deployer);
        console.log("PoolManager:   ", config.uniswapV4.poolManager);
        console.log("USDC:          ", config.tokens.USDC);
    }

    function _logDeploymentSummary(address deployer) internal view {
        console.log("\n\n================================================");
        console.log("  DEPLOYMENT COMPLETE");
        console.log("================================================");

        console.log("\n--- Core Contracts ---");
        console.log("  InstrumentRegistry:", address(registry));
        console.log("  SwapPoolRegistry:  ", address(swapPoolRegistry));
        console.log("  SwapDepositRouter: ", address(router));

        console.log("\n--- Adapters ---");
        if (address(aaveAdapter) != address(0)) {
            console.log("  AaveAdapter:       ", address(aaveAdapter));
        }
        if (address(compoundAdapter) != address(0)) {
            console.log("  CompoundAdapter:   ", address(compoundAdapter));
        }
        if (address(morphoAdapter) != address(0)) {
            console.log("  MorphoAdapter:     ", address(morphoAdapter));
        }
        if (address(eulerAdapter) != address(0)) {
            console.log("  EulerAdapter:      ", address(eulerAdapter));
        }
        if (address(fluidAdapter) != address(0)) {
            console.log("  FluidAdapter:      ", address(fluidAdapter));
        }

        console.log("\n--- CCTP ---");
        if (address(bridge) != address(0)) {
            console.log("  CCTPBridge:        ", address(bridge));
        } else {
            console.log("  CCTPBridge:         not deployed");
        }
        if (address(receiver) != address(0)) {
            console.log("  CCTPReceiver:      ", address(receiver));
        } else {
            console.log("  CCTPReceiver:       not deployed");
        }

        console.log("\n--- Network Info ---");
        console.log("  Network:     ", networkName);
        console.log("  Chain ID:    ", config.chainId);
        console.log("  Explorer:    ", config.explorer);
        console.log("  Deployer:    ", deployer);

        console.log("\n--- Next Steps ---");
        console.log("  1. Update NetworkConfig.json deployed section with addresses above");
        console.log("  2. Deploy on the other chain with the same script");
        console.log("  3. Update NetworkConfig.json cctp.destinations[].receiver");
        console.log("     with the CCTPReceiver address from each chain");
        console.log("  4. Run ConfigureCCTP on BOTH chains to set cross-chain receivers:");
        console.log("     forge script script/ConfigureCCTP.s.sol --rpc-url <chain> --broadcast");
        console.log("  5. Verify contracts on block explorer");
        console.log("================================================\n");
    }

    // ============================================
    // Helpers
    // ============================================

    function _generateInstrumentId(uint256 chainId, address executionAddress, bytes32 marketId)
        internal
        pure
        returns (bytes32 instrumentId)
    {
        bytes32 localHash = keccak256(abi.encode(executionAddress, marketId));
        assembly {
            instrumentId := or(shl(224, chainId), shr(32, localHash))
        }
    }
}
