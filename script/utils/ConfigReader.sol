// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

struct NetworkConfig {
    uint256 chainId;
    string explorer;
    UniswapV4Config uniswapV4;
    TokenConfig tokens;
    ProtocolConfig protocols;
    SwapPoolConfig[] swapPools;
}

struct SwapPoolConfig {
    string tokenIn;
    string tokenOut;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct UniswapV4Config {
    address poolManager;
    address positionManager;
    address swapRouter;
    address create2Deployer;
    address permit2;
}

struct TokenConfig {
    address USDC;
    address USDT;
    address DAI;
    address EURC;
    address USDbC;
    address GHO;
    address USDS;
    address eUSD;
    address WETH;
    address cbBTC;
}

struct ProtocolConfig {
    AaveConfig aave;
    MorphoConfig morpho;
    CompoundConfig compound;
    FluidConfig fluid;
    EulerEarnConfig eulerEarn;
}

struct AaveConfig {
    address pool;
}

struct MorphoConfig {
    MorphoVaults vaults;
}

struct MorphoVaults {
    // Base vaults
    address steakhouseUSDC;
    address sparkUSDC;
    address gauntletUSDCPrime;
    address steakhousePrimeUSDC;
    address re7EUSD;
    address clearstarUSDC;
    address mevFrontierUSDC;
    // Arbitrum vaults
    address clearstarHighYieldUSDC;
    // Unichain vaults
    address gauntletUSDCC;
    address kpkUSDCYield;
    address yearnDegenUSDC;
    address hyperithmUSDC;
    address clearstarUSDCReactor;
    address gauntletUSDCCore;
    address steakhouseHighYieldUSDC;
}

struct CompoundConfig {
    address configurator;
    address rewards;
    address bulker;
    address usdcComet;
    address usdbcComet;
    address usdsComet;
}

struct FluidConfig {
    address liquidity;
    address factory;
    FluidFTokens fTokens;
}

struct FluidFTokens {
    address fUSDC;
    address fEURC;
    address fGHO;
}

struct EulerEarnConfig {
    EulerEarnVaults vaults;
}

struct EulerEarnVaults {
    address eeUSDC;
}

struct CCTPConfig {
    address tokenMessenger;
    address messageTransmitter;
    uint32 domain;
    CCTPDestination[] destinations;
}

struct CCTPDestination {
    string name;
    uint32 chainId;
    uint32 domain;
    address receiver;
}

struct DeployedConfig {
    address instrumentRegistry;
    address swapPoolRegistry;
    address swapDepositorHook;
    address swapDepositorRouter;
    address instrumentToken;
    DeployedAdapters adapters;
    DeployedCCTP cctp;
}

struct DeployedAdapters {
    address aave;
    address compound;
    address morpho;
    address fluid;
    address euler;
}

struct DeployedCCTP {
    address cctpBridge;
    address cctpReceiver;
}

abstract contract ConfigReader is Script {
    using stdJson for string;

    string constant CONFIG_PATH = "script/config/NetworkConfig.json";

    function getNetworkConfig(string memory networkName) internal view returns (NetworkConfig memory config) {
        string memory json = vm.readFile(CONFIG_PATH);
        string memory networkPath = string.concat(".networks.", networkName);

        config.chainId = json.readUint(string.concat(networkPath, ".chainId"));
        config.explorer = json.readString(string.concat(networkPath, ".explorer"));

        // Uniswap V4 config
        config.uniswapV4 = _readUniswapV4Config(json, networkPath);

        // Token config
        config.tokens = _readTokenConfig(json, networkPath);

        // Protocol config
        config.protocols = _readProtocolConfig(json, networkPath);

        // Swap Pool config - read directly to avoid array copy issues
        _readSwapPoolConfigInPlace(json, networkPath, config);
    }

    function getDeployedConfig(string memory networkName) internal view returns (DeployedConfig memory deployed) {
        string memory json = vm.readFile(CONFIG_PATH);
        string memory networkPath = string.concat(".networks.", networkName);
        string memory deployedPath = string.concat(networkPath, ".deployed");

        deployed.instrumentRegistry = json.readAddress(string.concat(deployedPath, ".instrumentRegistry"));
        deployed.swapPoolRegistry = json.readAddress(string.concat(deployedPath, ".swapPoolRegistry"));
        deployed.swapDepositorHook = json.readAddress(string.concat(deployedPath, ".swapDepositorHook"));
        deployed.swapDepositorRouter = json.readAddress(string.concat(deployedPath, ".swapDepositorRouter"));

        string memory cctpBridgePath = string.concat(deployedPath, ".cctpBridge");
        if (vm.keyExistsJson(json, cctpBridgePath)) {
            deployed.cctp.cctpBridge = json.readAddress(cctpBridgePath);
        }
        string memory cctpReceiverPath = string.concat(deployedPath, ".cctpReceiver");
        if (vm.keyExistsJson(json, cctpReceiverPath)) {
            deployed.cctp.cctpReceiver = json.readAddress(cctpReceiverPath);
        }
        deployed.instrumentToken = json.readAddress(string.concat(deployedPath, ".instrumentToken"));
        deployed.adapters.aave = json.readAddress(string.concat(deployedPath, ".adapters.aave"));
        deployed.adapters.compound = json.readAddress(string.concat(deployedPath, ".adapters.compound"));
        deployed.adapters.morpho = json.readAddress(string.concat(deployedPath, ".adapters.morpho"));
        deployed.adapters.fluid = json.readAddress(string.concat(deployedPath, ".adapters.fluid"));

        string memory eulerPath = string.concat(deployedPath, ".adapters.euler");
        if (vm.keyExistsJson(json, eulerPath)) {
            deployed.adapters.euler = json.readAddress(eulerPath);
        }
    }

    function _readUniswapV4Config(string memory json, string memory networkPath)
        private
        pure
        returns (UniswapV4Config memory uniswapV4)
    {
        uniswapV4.poolManager = json.readAddress(string.concat(networkPath, ".uniswapV4.poolManager"));
        uniswapV4.positionManager = json.readAddress(string.concat(networkPath, ".uniswapV4.positionManager"));
        uniswapV4.swapRouter = json.readAddress(string.concat(networkPath, ".uniswapV4.swapRouter"));
        uniswapV4.create2Deployer = json.readAddress(string.concat(networkPath, ".uniswapV4.create2Deployer"));
        uniswapV4.permit2 = json.readAddress(string.concat(networkPath, ".uniswapV4.permit2"));
    }

    function _readTokenConfig(string memory json, string memory networkPath)
        private
        view
        returns (TokenConfig memory tokens)
    {
        tokens.USDC = json.readAddress(string.concat(networkPath, ".tokens.USDC"));

        // Optional stablecoins
        string memory usdtPath = string.concat(networkPath, ".tokens.USDT");
        if (vm.keyExistsJson(json, usdtPath)) {
            tokens.USDT = json.readAddress(usdtPath);
        }

        string memory daiPath = string.concat(networkPath, ".tokens.DAI");
        if (vm.keyExistsJson(json, daiPath)) {
            tokens.DAI = json.readAddress(daiPath);
        }

        string memory eurcPath = string.concat(networkPath, ".tokens.EURC");
        if (vm.keyExistsJson(json, eurcPath)) {
            tokens.EURC = json.readAddress(eurcPath);
        }

        string memory usdbcPath = string.concat(networkPath, ".tokens.USDbC");
        if (vm.keyExistsJson(json, usdbcPath)) {
            tokens.USDbC = json.readAddress(usdbcPath);
        }

        string memory ghoPath = string.concat(networkPath, ".tokens.GHO");
        if (vm.keyExistsJson(json, ghoPath)) {
            tokens.GHO = json.readAddress(ghoPath);
        }

        string memory usdsPath = string.concat(networkPath, ".tokens.USDS");
        if (vm.keyExistsJson(json, usdsPath)) {
            tokens.USDS = json.readAddress(usdsPath);
        }

        string memory eusdPath = string.concat(networkPath, ".tokens.eUSD");
        if (vm.keyExistsJson(json, eusdPath)) {
            tokens.eUSD = json.readAddress(eusdPath);
        }

        string memory wethPath = string.concat(networkPath, ".tokens.WETH");
        if (vm.keyExistsJson(json, wethPath)) {
            tokens.WETH = json.readAddress(wethPath);
        }

        string memory cbBTCPath = string.concat(networkPath, ".tokens.cbBTC");
        if (vm.keyExistsJson(json, cbBTCPath)) {
            tokens.cbBTC = json.readAddress(cbBTCPath);
        }
    }

    function _readProtocolConfig(string memory json, string memory networkPath)
        private
        view
        returns (ProtocolConfig memory protocols)
    {
        string memory aavePoolPath = string.concat(networkPath, ".protocols.aave.pool");
        if (vm.keyExistsJson(json, aavePoolPath)) {
            protocols.aave.pool = json.readAddress(aavePoolPath);
        }

        // Optional Morpho config
        protocols.morpho = _readMorphoConfig(json, networkPath);

        // Optional Compound config
        protocols.compound = _readCompoundConfig(json, networkPath);

        // Optional Fluid config
        protocols.fluid = _readFluidConfig(json, networkPath);

        // Optional EulerEarn config
        protocols.eulerEarn = _readEulerEarnConfig(json, networkPath);
    }

    function _readMorphoConfig(string memory json, string memory networkPath)
        private
        view
        returns (MorphoConfig memory morpho)
    {
        string memory vaultsPath = string.concat(networkPath, ".protocols.morpho.vaults");
        if (!vm.keyExistsJson(json, vaultsPath)) {
            return morpho;
        }

        // Read Base vaults
        morpho.vaults.steakhouseUSDC = _readVaultAddress(json, vaultsPath, ".steakhouseUSDC");
        morpho.vaults.sparkUSDC = _readVaultAddress(json, vaultsPath, ".sparkUSDC");
        morpho.vaults.gauntletUSDCPrime = _readVaultAddress(json, vaultsPath, ".gauntletUSDCPrime");
        morpho.vaults.steakhousePrimeUSDC = _readVaultAddress(json, vaultsPath, ".steakhousePrimeUSDC");
        morpho.vaults.re7EUSD = _readVaultAddress(json, vaultsPath, ".re7EUSD");
        morpho.vaults.clearstarUSDC = _readVaultAddress(json, vaultsPath, ".clearstarUSDC");
        morpho.vaults.mevFrontierUSDC = _readVaultAddress(json, vaultsPath, ".mevFrontierUSDC");

        // Read Arbitrum vaults
        morpho.vaults.clearstarHighYieldUSDC = _readVaultAddress(json, vaultsPath, ".clearstarHighYieldUSDC");
        morpho.vaults.kpkUSDCYield = _readVaultAddress(json, vaultsPath, ".kpkUSDCYield");
        morpho.vaults.yearnDegenUSDC = _readVaultAddress(json, vaultsPath, ".yearnDegenUSDC");
        morpho.vaults.hyperithmUSDC = _readVaultAddress(json, vaultsPath, ".hyperithmUSDC");
        morpho.vaults.clearstarUSDCReactor = _readVaultAddress(json, vaultsPath, ".clearstarUSDCReactor");
        morpho.vaults.gauntletUSDCCore = _readVaultAddress(json, vaultsPath, ".gauntletUSDCCore");
        morpho.vaults.steakhouseHighYieldUSDC = _readVaultAddress(json, vaultsPath, ".steakhouseHighYieldUSDC");

        // Read Unichain vaults
        morpho.vaults.gauntletUSDCC = _readVaultAddress(json, vaultsPath, ".gauntletUSDCC");
    }

    /// @notice Helper to read a vault address if it exists
    function _readVaultAddress(string memory json, string memory vaultsPath, string memory vaultKey)
        private
        view
        returns (address)
    {
        string memory fullPath = string.concat(vaultsPath, vaultKey);
        if (vm.keyExistsJson(json, fullPath)) {
            return json.readAddress(fullPath);
        }
        return address(0);
    }

    function _readCompoundConfig(string memory json, string memory networkPath)
        private
        view
        returns (CompoundConfig memory compound)
    {
        string memory configuratorPath = string.concat(networkPath, ".protocols.compound.configurator");
        if (!vm.keyExistsJson(json, configuratorPath)) {
            return compound;
        }

        compound.configurator = json.readAddress(configuratorPath);

        string memory rewardsPath = string.concat(networkPath, ".protocols.compound.rewards");
        if (vm.keyExistsJson(json, rewardsPath)) {
            compound.rewards = json.readAddress(rewardsPath);
        }

        string memory bulkerPath = string.concat(networkPath, ".protocols.compound.bulker");
        if (vm.keyExistsJson(json, bulkerPath)) {
            compound.bulker = json.readAddress(bulkerPath);
        }

        // Parse markets
        _readCompoundMarkets(json, networkPath, compound);
    }

    function _readCompoundMarkets(string memory json, string memory networkPath, CompoundConfig memory compound)
        private
        view
    {
        string memory usdcMarketPath = string.concat(networkPath, ".protocols.compound.usdcComet");
        if (vm.keyExistsJson(json, usdcMarketPath)) {
            compound.usdcComet = json.readAddress(usdcMarketPath);
        }

        string memory usdbcMarketPath = string.concat(networkPath, ".protocols.compound.usdbcComet");
        if (vm.keyExistsJson(json, usdbcMarketPath)) {
            compound.usdbcComet = json.readAddress(usdbcMarketPath);
        }

        string memory usdsMarketPath = string.concat(networkPath, ".protocols.compound.usdsComet");
        if (vm.keyExistsJson(json, usdsMarketPath)) {
            compound.usdsComet = json.readAddress(usdsMarketPath);
        }
    }

    function _readFluidConfig(string memory json, string memory networkPath)
        private
        view
        returns (FluidConfig memory fluid)
    {
        string memory liquidityPath = string.concat(networkPath, ".protocols.fluid.liquidity");
        if (!vm.keyExistsJson(json, liquidityPath)) {
            return fluid;
        }

        fluid.liquidity = json.readAddress(liquidityPath);

        string memory factoryPath = string.concat(networkPath, ".protocols.fluid.factory");
        if (vm.keyExistsJson(json, factoryPath)) {
            fluid.factory = json.readAddress(factoryPath);
        }

        // Parse fTokens
        _readFluidFTokens(json, networkPath, fluid);
    }

    function _readFluidFTokens(string memory json, string memory networkPath, FluidConfig memory fluid) private view {
        string memory fUSDCPath = string.concat(networkPath, ".protocols.fluid.fTokens.fUSDC");
        if (vm.keyExistsJson(json, fUSDCPath)) {
            fluid.fTokens.fUSDC = json.readAddress(fUSDCPath);
        }

        string memory fEURCPath = string.concat(networkPath, ".protocols.fluid.fTokens.fEURC");
        if (vm.keyExistsJson(json, fEURCPath)) {
            fluid.fTokens.fEURC = json.readAddress(fEURCPath);
        }

        string memory fGHOPath = string.concat(networkPath, ".protocols.fluid.fTokens.fGHO");
        if (vm.keyExistsJson(json, fGHOPath)) {
            fluid.fTokens.fGHO = json.readAddress(fGHOPath);
        }
    }

    function _readEulerEarnConfig(string memory json, string memory networkPath)
        private
        view
        returns (EulerEarnConfig memory eulerEarn)
    {
        string memory vaultsPath = string.concat(networkPath, ".protocols.eulerEarn.vaults");
        if (!vm.keyExistsJson(json, vaultsPath)) {
            return eulerEarn;
        }

        string memory eeUSDCPath = string.concat(vaultsPath, ".eeUSDC");
        if (vm.keyExistsJson(json, eeUSDCPath)) {
            eulerEarn.vaults.eeUSDC = json.readAddress(eeUSDCPath);
        }
    }

    function _readSwapPoolConfigInPlace(string memory json, string memory networkPath, NetworkConfig memory config)
        private
        view
    {
        string memory swapPoolsPath = string.concat(networkPath, ".swapPools");
        if (!vm.keyExistsJson(json, swapPoolsPath)) {
            return;
        }

        // Count the number of pools
        uint256 poolCount = _countSwapPools(json, swapPoolsPath);

        // Parse each pool individually
        config.swapPools = new SwapPoolConfig[](poolCount);
        for (uint256 i = 0; i < poolCount; i++) {
            config.swapPools[i] = _readSingleSwapPool(json, swapPoolsPath, i);
        }
    }

    function _countSwapPools(string memory json, string memory swapPoolsPath) private view returns (uint256 poolCount) {
        while (true) {
            string memory poolPath = string.concat(swapPoolsPath, "[", vm.toString(poolCount), "]");
            if (!vm.keyExistsJson(json, poolPath)) break;
            poolCount++;
        }
    }

    function _readSingleSwapPool(string memory json, string memory swapPoolsPath, uint256 index)
        private
        pure
        returns (SwapPoolConfig memory pool)
    {
        string memory basePath = string.concat(swapPoolsPath, "[", vm.toString(index), "]");
        pool = SwapPoolConfig({
            tokenIn: json.readString(string.concat(basePath, ".tokenIn")),
            tokenOut: json.readString(string.concat(basePath, ".tokenOut")),
            fee: uint24(json.readUint(string.concat(basePath, ".fee"))),
            tickSpacing: int24(int256(json.readUint(string.concat(basePath, ".tickSpacing")))),
            hooks: json.readAddress(string.concat(basePath, ".hooks"))
        });
    }

    function getAaveTokenAddress(string memory networkName, string memory tokenSymbol) internal view returns (address) {
        string memory json = vm.readFile(CONFIG_PATH);
        string memory tokenPath = string.concat(".networks.", networkName, ".protocols.aave.aTokens.", tokenSymbol);

        try vm.parseJsonAddress(json, tokenPath) returns (address tokenAddress) {
            return tokenAddress;
        } catch {
            return address(0);
        }
    }

    function getCCTPConfig(string memory networkName) internal view returns (CCTPConfig memory cctp) {
        string memory json = vm.readFile(CONFIG_PATH);
        string memory cctpPath = string.concat(".networks.", networkName, ".cctp");
        if (!vm.keyExistsJson(json, cctpPath)) return cctp;

        cctp.tokenMessenger = json.readAddress(string.concat(cctpPath, ".tokenMessenger"));
        cctp.domain = uint32(json.readUint(string.concat(cctpPath, ".domain")));

        string memory transmitterPath = string.concat(cctpPath, ".messageTransmitter");
        if (vm.keyExistsJson(json, transmitterPath)) {
            cctp.messageTransmitter = json.readAddress(transmitterPath);
        }

        string memory destPath = string.concat(cctpPath, ".destinations");
        if (!vm.keyExistsJson(json, destPath)) return cctp;

        string[] memory destKeys = vm.parseJsonKeys(json, destPath);
        cctp.destinations = new CCTPDestination[](destKeys.length);
        for (uint256 i = 0; i < destKeys.length; i++) {
            string memory dp = string.concat(destPath, ".", destKeys[i]);
            cctp.destinations[i] = CCTPDestination({
                name: destKeys[i],
                chainId: uint32(json.readUint(string.concat(dp, ".chainId"))),
                domain: uint32(json.readUint(string.concat(dp, ".domain"))),
                receiver: json.readAddress(string.concat(dp, ".receiver"))
            });
        }
    }

    function isNetworkSupported(string memory networkName) internal view returns (bool) {
        string memory json = vm.readFile(CONFIG_PATH);
        string memory networkPath = string.concat(".networks.", networkName);

        try vm.parseJsonUint(json, string.concat(networkPath, ".chainId")) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    function getAllSupportedNetworks() internal view returns (string[] memory) {
        string memory json = vm.readFile(CONFIG_PATH);
        return vm.parseJsonKeys(json, ".networks");
    }

    function detectNetworkFromChainId(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 84532) return "baseSepolia";
        if (chainId == 8453) return "baseMainnet";
        if (chainId == 421614) return "arbitrumSepolia";
        if (chainId == 42161) return "arbitrumMainnet";
        if (chainId == 1) return "ethereum";
        if (chainId == 130) return "unichainMainnet";
        revert("Unsupported network");
    }
}
