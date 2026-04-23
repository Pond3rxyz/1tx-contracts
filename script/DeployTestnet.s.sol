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
import {ConfigReader, NetworkConfig, CCTPConfig} from "./utils/ConfigReader.sol";

/// @notice Deploys everything needed on a testnet chain: registries + router + bridge + receiver
contract DeployTestnet is ConfigReader {
    function run() external {
        string memory networkName = detectNetworkFromChainId(block.chainid);
        NetworkConfig memory config = getNetworkConfig(networkName);
        CCTPConfig memory cctp = getCCTPConfig(networkName);

        address deployer = msg.sender;

        console.log("=== Deploy Testnet Full Stack ===");
        console.log("Network:", networkName);
        console.log("ChainId:", block.chainid);
        console.log("Deployer:", deployer);

        vm.startBroadcast();

        // 1. InstrumentRegistry
        InstrumentRegistry irImpl = new InstrumentRegistry();
        address irProxy = address(
            new ERC1967Proxy(address(irImpl), abi.encodeWithSelector(InstrumentRegistry.initialize.selector, deployer))
        );
        console.log("InstrumentRegistry:", irProxy);

        // 2. SwapPoolRegistry
        SwapPoolRegistry sprImpl = new SwapPoolRegistry();
        address sprProxy = address(
            new ERC1967Proxy(address(sprImpl), abi.encodeWithSelector(SwapPoolRegistry.initialize.selector, deployer))
        );
        console.log("SwapPoolRegistry:", sprProxy);

        // 3. SwapDepositRouter
        SwapDepositRouter routerImpl = new SwapDepositRouter();
        address routerProxy = address(
            new ERC1967Proxy(
                address(routerImpl),
                abi.encodeWithSelector(
                    SwapDepositRouter.initialize.selector,
                    deployer,
                    IPoolManager(config.uniswapV4.poolManager),
                    InstrumentRegistry(irProxy),
                    SwapPoolRegistry(sprProxy),
                    Currency.wrap(config.tokens.USDC)
                )
            )
        );
        console.log("SwapDepositRouter:", routerProxy);

        // 4. CCTPBridge (if tokenMessenger configured)
        if (cctp.tokenMessenger != address(0)) {
            CCTPBridge bridgeImpl = new CCTPBridge();
            address bridgeProxy = address(
                new ERC1967Proxy(address(bridgeImpl), abi.encodeWithSelector(CCTPBridge.initialize.selector, deployer))
            );
            console.log("CCTPBridge:", bridgeProxy);
        }

        // 5. CCTPReceiver (if messageTransmitter configured)
        if (cctp.messageTransmitter != address(0)) {
            CCTPReceiver receiverImpl = new CCTPReceiver();
            address receiverProxy = address(
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
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Update NetworkConfig.json with these addresses ===");
    }
}
