// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PortfolioVault} from "../src/hooks/PortfolioVault.sol";
import {PortfolioStrategy} from "../src/hooks/PortfolioStrategy.sol";
import {PortfolioFactory} from "../src/hooks/PortfolioFactory.sol";
import {PortfolioFactoryHelper} from "../src/hooks/PortfolioFactoryHelper.sol";
import {InstrumentRegistry} from "../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../src/registries/SwapPoolRegistry.sol";
import {IPortfolioStrategy} from "../src/interfaces/IPortfolioStrategy.sol";

import {AdapterBase} from "../src/adapters/base/AdapterBase.sol";
import {ConfigReader, NetworkConfig, DeployedConfig} from "./utils/ConfigReader.sol";

/// @title DeployPortfolioFactory
/// @notice Deploys the shared PortfolioStrategy (upgradeable) and PortfolioFactory
///
/// Usage:
///   FOUNDRY_PROFILE=deploy forge script script/DeployPortfolioFactory.s.sol:DeployPortfolioFactory \
///     --rpc-url <network> --account <keystore> --broadcast -vvvv
contract DeployPortfolioFactory is ConfigReader {
    function run() external {
        string memory networkName = detectNetworkFromChainId(block.chainid);
        NetworkConfig memory config = getNetworkConfig(networkName);
        DeployedConfig memory deployed = getDeployedConfig(networkName);

        address deployer = msg.sender;

        console.log("=== Deploy PortfolioFactory ===");
        console.log("Network:", networkName);
        console.log("Chain ID:", config.chainId);
        console.log("Deployer:", deployer);

        vm.startBroadcast();

        // 1. Deploy shared strategy (UUPS upgradeable)
        PortfolioStrategy strategyImpl = new PortfolioStrategy();
        PortfolioStrategy strategy = PortfolioStrategy(
            address(
                new ERC1967Proxy(
                    address(strategyImpl), abi.encodeWithSelector(PortfolioStrategy.initialize.selector, deployer)
                )
            )
        );
        console.log("PortfolioStrategy implementation:", address(strategyImpl));
        console.log("PortfolioStrategy proxy:", address(strategy));

        // 2. Deploy factory
        PortfolioFactory factory = new PortfolioFactory(
            IPoolManager(config.uniswapV4.poolManager),
            InstrumentRegistry(deployed.instrumentRegistry),
            SwapPoolRegistry(deployed.swapPoolRegistry),
            IPortfolioStrategy(address(strategy))
        );
        console.log("PortfolioFactory:", address(factory));

        // 3. Deploy factory helper (view functions for frontend)
        PortfolioFactoryHelper factoryHelper = new PortfolioFactoryHelper(
            address(factory),
            IPoolManager(config.uniswapV4.poolManager),
            InstrumentRegistry(deployed.instrumentRegistry),
            SwapPoolRegistry(deployed.swapPoolRegistry),
            IPortfolioStrategy(address(strategy))
        );
        console.log("PortfolioFactoryHelper:", address(factoryHelper));

        // 4. Authorize strategy on all deployed adapters
        address[5] memory adapters = [
            deployed.adapters.aave,
            deployed.adapters.compound,
            deployed.adapters.morpho,
            deployed.adapters.euler,
            deployed.adapters.fluid
        ];
        string[5] memory names = ["Aave", "Compound", "Morpho", "Euler", "Fluid"];

        for (uint256 i = 0; i < adapters.length; i++) {
            if (adapters[i] != address(0)) {
                AdapterBase(adapters[i]).addAuthorizedCaller(address(strategy));
                console.log(string.concat("  Authorized strategy on ", names[i], " adapter:"), adapters[i]);
            }
        }

        vm.stopBroadcast();

        console.log("=== Deployment Complete ===");
        console.log("Update NetworkConfig.json with:");
        console.log("  portfolioStrategy:", address(strategy));
        console.log("  portfolioFactory:", address(factory));
        console.log("  portfolioFactoryHelper:", address(factoryHelper));
    }
}
