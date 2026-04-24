// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SwapDepositRouter} from "../src/SwapDepositRouter.sol";
import {InstrumentIdLib} from "../src/libraries/InstrumentIdLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ConfigReader, NetworkConfig, DeployedConfig, CCTPConfig, CCTPDestination} from "./utils/ConfigReader.sol";

/// @notice Tests the cross-chain bridge flow by calling the canonical buy() entrypoint with a remote-chain instrumentId
/// @dev This triggers: SwapDepositRouter.buy() -> _bridgeForCrossChainInstrument() -> CCTPBridge.bridge()
///
/// Usage:
///   forge script script/TestBridge.s.sol:TestBridge \
///     --rpc-url baseSepolia --account <keystore> --broadcast \
///     --sig "run(uint256)" 1000000
///
///   The argument is the USDC amount in raw units (1000000 = 1 USDC on 6-decimal tokens).
///   Requires the sender to have USDC and an approval to the SwapDepositRouter.
contract TestBridge is ConfigReader {
    function run(uint256 amount) external {
        string memory networkName = detectNetworkFromChainId(block.chainid);
        NetworkConfig memory config = getNetworkConfig(networkName);
        DeployedConfig memory deployed = getDeployedConfig(networkName);
        CCTPConfig memory cctp = getCCTPConfig(networkName);

        require(deployed.swapDepositorRouter != address(0), "Router not deployed");
        require(cctp.destinations.length > 0, "No CCTP destinations");

        bytes32 instrumentId = _buildRemoteInstrumentId(cctp.destinations[0]);

        _logInfo(networkName, config, deployed, cctp.destinations[0], instrumentId, amount);

        _execute(config.tokens.USDC, deployed.swapDepositorRouter, instrumentId, amount);
    }

    function _buildRemoteInstrumentId(CCTPDestination memory dest) internal view returns (bytes32) {
        NetworkConfig memory destConfig = getNetworkConfig(dest.name);
        bytes32 marketId = InstrumentIdLib.generateSingleAssetMarketId(Currency.wrap(destConfig.tokens.USDC));
        return InstrumentIdLib.generateInstrumentId(dest.chainId, destConfig.protocols.aave.pool, marketId);
    }

    function _logInfo(
        string memory networkName,
        NetworkConfig memory config,
        DeployedConfig memory deployed,
        CCTPDestination memory dest,
        bytes32 instrumentId,
        uint256 amount
    ) internal view {
        console.log("=== Test Cross-Chain Bridge ===");
        console.log("Network:", networkName);
        console.log("Sender:", msg.sender);
        console.log("Router:", deployed.swapDepositorRouter);
        console.log("USDC:", config.tokens.USDC);
        console.log("Amount:", amount);
        console.log("Destination:", dest.name);
        console.log("Dest chainId:", uint256(dest.chainId));
        console.log("InstrumentId:");
        console.logBytes32(instrumentId);

        uint256 balance = IERC20(config.tokens.USDC).balanceOf(msg.sender);
        console.log("Sender USDC balance:", balance);
        require(balance >= amount, "Insufficient USDC balance");
        console.log("Sender allowance:", IERC20(config.tokens.USDC).allowance(msg.sender, deployed.swapDepositorRouter));
    }

    function _execute(address usdc, address routerAddr, bytes32 instrumentId, uint256 amount) internal {
        SwapDepositRouter router = SwapDepositRouter(routerAddr);

        vm.startBroadcast();

        // Approve router if needed
        if (IERC20(usdc).allowance(msg.sender, routerAddr) < amount) {
            IERC20(usdc).approve(routerAddr, type(uint256).max);
            console.log("Approved router for max USDC");
        }

        // Call the canonical buy entrypoint with zero referral args; this triggers the bridge.
        // fastTransfer=true, maxFee=50000 (0.05 USDC / 5%), minDepositedAmount=0 for testing
        router.buy(instrumentId, amount, 0, true, 50000, 0, address(0));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Bridge initiated successfully ===");
        console.log("Check CCTP attestation service for message status");
    }
}
