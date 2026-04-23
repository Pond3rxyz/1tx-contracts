// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {SwapDepositRouter} from "../src/SwapDepositRouter.sol";
import {CCTPBridge} from "../src/CCTPBridge.sol";
import {CCTPReceiver} from "../src/CCTPReceiver.sol";
import {InstrumentRegistry} from "../src/registries/InstrumentRegistry.sol";
import {SwapPoolRegistry} from "../src/registries/SwapPoolRegistry.sol";
import {ConfigReader, NetworkConfig, DeployedConfig, CCTPConfig} from "./utils/ConfigReader.sol";

/// @notice Deploys SwapDepositRouter + CCTPBridge + CCTPReceiver (deploy only, no cross-chain wiring)
/// @dev After deploying: update NetworkConfig.json with addresses, then run ConfigureCCTP
contract DeployAll is ConfigReader {
    function run() external {
        string memory networkName = detectNetworkFromChainId(block.chainid);
        NetworkConfig memory config = getNetworkConfig(networkName);
        DeployedConfig memory deployed = getDeployedConfig(networkName);
        CCTPConfig memory cctp = getCCTPConfig(networkName);

        address deployer = msg.sender;

        console.log("=== Deploy All ===");
        console.log("Network:", networkName);
        console.log("Deployer:", deployer);

        require(deployed.instrumentRegistry != address(0), "InstrumentRegistry not deployed");
        require(deployed.swapPoolRegistry != address(0), "SwapPoolRegistry not deployed");

        vm.startBroadcast();

        // 1. SwapDepositRouter
        SwapDepositRouter routerImpl = new SwapDepositRouter();
        address routerProxy = address(
            new ERC1967Proxy(
                address(routerImpl),
                abi.encodeWithSelector(
                    SwapDepositRouter.initialize.selector,
                    deployer,
                    IPoolManager(config.uniswapV4.poolManager),
                    InstrumentRegistry(deployed.instrumentRegistry),
                    SwapPoolRegistry(deployed.swapPoolRegistry),
                    Currency.wrap(config.tokens.USDC)
                )
            )
        );
        console.log("SwapDepositRouter:", routerProxy);

        // 2. CCTPBridge
        address bridgeProxy;
        if (cctp.tokenMessenger != address(0)) {
            CCTPBridge bridgeImpl = new CCTPBridge();
            bridgeProxy = address(
                new ERC1967Proxy(address(bridgeImpl), abi.encodeWithSelector(CCTPBridge.initialize.selector, deployer))
            );
            console.log("CCTPBridge:", bridgeProxy);
        } else {
            console.log("CCTPBridge: SKIPPED (no tokenMessenger)");
        }

        // 3. CCTPReceiver
        address receiverProxy;
        if (cctp.messageTransmitter != address(0)) {
            CCTPReceiver receiverImpl = new CCTPReceiver();
            receiverProxy = address(
                new ERC1967Proxy(
                    address(receiverImpl),
                    abi.encodeWithSelector(
                        CCTPReceiver.initialize.selector,
                        deployer,
                        routerProxy,
                        config.tokens.USDC,
                        cctp.messageTransmitter
                    )
                )
            );
            console.log("CCTPReceiver:", receiverProxy);
        } else {
            console.log("CCTPReceiver: SKIPPED (no messageTransmitter)");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Update NetworkConfig.json with these addresses ===");
        console.log("deployed.swapDepositorRouter:", routerProxy);
        if (bridgeProxy != address(0)) console.log("deployed.cctpBridge:", bridgeProxy);
        if (receiverProxy != address(0)) console.log("deployed.cctpReceiver:", receiverProxy);
        console.log("");
        console.log("Then run: ConfigureCCTP to wire all contracts");
    }
}
