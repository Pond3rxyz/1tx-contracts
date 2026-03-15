// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CCTPReceiver} from "../src/CCTPReceiver.sol";
import {ConfigReader, NetworkConfig, DeployedConfig} from "./utils/ConfigReader.sol";

/// @notice Redeems a CCTP message on the destination chain via CCTPReceiver
/// @dev Expects buyFor to fail on testnet (different USDC addresses per chain),
///      so the CCTPReceiver fallback sends USDC directly to the recipient.
///
/// Usage:
///   forge script script/TestBridgeRedeem.s.sol:TestBridgeRedeem \
///     --rpc-url arbitrumSepolia --account <keystore> --broadcast \
///     --sig "run(bytes,bytes)" <message_hex> <attestation_hex>
///
///   message and attestation are obtained from the source chain tx + Circle attestation API.
///   Use test-bridge.sh to automate the full flow.
contract TestBridgeRedeem is ConfigReader {
    function run(bytes calldata message, bytes calldata attestation) external {
        string memory networkName = detectNetworkFromChainId(block.chainid);
        NetworkConfig memory config = getNetworkConfig(networkName);
        DeployedConfig memory deployed = getDeployedConfig(networkName);

        address receiverAddr = deployed.cctp.cctpReceiver;

        console.log("=== Redeem CCTP Message ===");
        console.log("Network:", networkName);
        console.log("CCTPReceiver:", receiverAddr);
        console.log("Message length:", message.length);
        console.log("Attestation length:", attestation.length);

        require(receiverAddr != address(0), "CCTPReceiver not deployed");

        // Check USDC balance before
        address usdc = config.tokens.USDC;
        uint256 receiverBalBefore = IERC20(usdc).balanceOf(receiverAddr);
        console.log("Receiver USDC balance before:", receiverBalBefore);

        vm.startBroadcast();

        CCTPReceiver receiver = CCTPReceiver(receiverAddr);
        bool success = receiver.redeem(message, attestation);

        vm.stopBroadcast();

        uint256 receiverBalAfter = IERC20(usdc).balanceOf(receiverAddr);
        console.log("Receiver USDC balance after:", receiverBalAfter);
        console.log("Redeem returned:", success);
        console.log("");

        if (success) {
            console.log("=== Redeem successful ===");
            console.log("If buyFor failed, USDC was sent directly to recipient (check events)");
        } else {
            console.log("=== Redeem failed ===");
        }
    }
}
