// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {SwapDepositRouter} from "../src/SwapDepositRouter.sol";
import {CCTPBridge} from "../src/CCTPBridge.sol";
import {
    ConfigReader,
    NetworkConfig,
    DeployedConfig,
    CCTPConfig,
    CCTPDestination
} from "./utils/ConfigReader.sol";

/// @notice Wires SwapDepositRouter, CCTPBridge, and CCTPReceiver using addresses from NetworkConfig.json
/// @dev Run this AFTER deploying all three contracts on all chains and updating the JSON with their addresses.
///
/// What it does:
///   1. CCTPBridge: setTokenMessenger, setAuthorizedCaller(router), destination domains + mint recipients
///   2. SwapDepositRouter: setCCTPBridge, setCCTPReceiver
///
/// Prerequisites in NetworkConfig.json:
///   - deployed.swapDepositorRouter must be set
///   - deployed.cctpBridge must be set
///   - deployed.cctpReceiver must be set
///   - cctp.destinations[].receiver must point to the CCTPReceiver on the destination chain
contract ConfigureCCTP is ConfigReader {
    function run() external {
        string memory networkName = detectNetworkFromChainId(block.chainid);
        DeployedConfig memory deployed = getDeployedConfig(networkName);
        CCTPConfig memory cctp = getCCTPConfig(networkName);

        address deployer = msg.sender;

        console.log("=== Configure CCTP ===");
        console.log("Network:", networkName);
        console.log("Deployer:", deployer);
        console.log("Router:", deployed.swapDepositorRouter);
        console.log("CCTPBridge:", deployed.cctp.cctpBridge);
        console.log("CCTPReceiver:", deployed.cctp.cctpReceiver);

        require(deployed.swapDepositorRouter != address(0), "swapDepositorRouter not set");
        require(deployed.cctp.cctpBridge != address(0), "cctpBridge not set");
        require(deployed.cctp.cctpReceiver != address(0), "cctpReceiver not set");
        require(cctp.tokenMessenger != address(0), "tokenMessenger not configured");

        SwapDepositRouter router = SwapDepositRouter(deployed.swapDepositorRouter);
        CCTPBridge bridge = CCTPBridge(deployed.cctp.cctpBridge);

        vm.startBroadcast();

        // --- CCTPBridge configuration ---
        bridge.setTokenMessenger(cctp.tokenMessenger);
        console.log("Bridge: tokenMessenger set");

        bridge.setAuthorizedCaller(deployed.swapDepositorRouter, true);
        console.log("Bridge: router authorized");

        for (uint256 i = 0; i < cctp.destinations.length; ++i) {
            CCTPDestination memory dest = cctp.destinations[i];

            bridge.setDestinationDomain(dest.chainId, dest.domain);
            console.log("Bridge: destination domain set for", dest.name);

            if (dest.receiver != address(0)) {
                bytes32 recipient = bytes32(uint256(uint160(dest.receiver)));
                bridge.setDestinationMintRecipient(dest.chainId, recipient);
                bridge.setDestinationCaller(dest.chainId, recipient);
                console.log("  mintRecipient + destinationCaller:", dest.receiver);
            }
        }

        // --- SwapDepositRouter configuration ---
        router.setCCTPBridge(deployed.cctp.cctpBridge);
        console.log("Router: cctpBridge set");

        router.setCCTPReceiver(deployed.cctp.cctpReceiver);
        console.log("Router: cctpReceiver set");

        vm.stopBroadcast();

        console.log("");
        console.log("=== CCTP configuration complete ===");
    }
}
