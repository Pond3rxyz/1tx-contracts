// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";

import {SwapDepositRouter} from "../src/SwapDepositRouter.sol";
import {ConfigReader, DeployedConfig} from "./utils/ConfigReader.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

// Force V1 into the build so openzeppelin-foundry-upgrades can find it as the
// reference for storage-layout validation, even under `--skip test`.
import {SwapDepositRouterV1} from "../test/fork/upgrade/legacy/SwapDepositRouterV1.sol";

/// @notice Upgrades the SwapDepositRouter proxy to a new implementation on the current chain.
/// @dev Reads the proxy address from NetworkConfig.json based on block.chainid.
///
/// Usage (per chain) — broadcast + Etherscan verification of the new implementation:
///   FOUNDRY_PROFILE=deploy forge script script/UpgradeSwapDepositRouter.s.sol \
///     --rpc-url $RPC_URL --broadcast --verify
///
/// Post-upgrade: call `setFeeConfig(...)` from the owner in a separate tx to activate fees.
contract UpgradeSwapDepositRouter is ConfigReader {
    function run() external {
        string memory networkName = detectNetworkFromChainId(block.chainid);
        DeployedConfig memory deployed = getDeployedConfig(networkName);

        require(deployed.swapDepositorRouter != address(0), "swapDepositorRouter not set in config");

        SwapDepositRouter proxy = SwapDepositRouter(deployed.swapDepositorRouter);

        // Snapshot pre-upgrade state
        address prevPoolManager = address(proxy.poolManager());
        address prevInstrumentRegistry = address(proxy.instrumentRegistry());
        address prevSwapPoolRegistry = address(proxy.swapPoolRegistry());
        address prevStable = Currency.unwrap(proxy.stable());
        address prevCctpBridge = proxy.cctpBridge();
        address prevCctpReceiver = proxy.cctpReceiver();
        address prevOwner = proxy.owner();

        console.log("=== Upgrade SwapDepositRouter ===");
        console.log("Network:          ", networkName);
        console.log("ChainId:          ", block.chainid);
        console.log("Proxy:            ", address(proxy));
        console.log("Owner:            ", prevOwner);
        console.log("Sender:           ", msg.sender);
        console.log("");
        console.log("--- Pre-upgrade state ---");
        console.log("poolManager:      ", prevPoolManager);
        console.log("instrumentRegistry:", prevInstrumentRegistry);
        console.log("swapPoolRegistry: ", prevSwapPoolRegistry);
        console.log("stable:           ", prevStable);
        console.log("cctpBridge:       ", prevCctpBridge);
        console.log("cctpReceiver:     ", prevCctpReceiver);

        require(msg.sender == prevOwner, "Sender is not the proxy owner");

        // Storage-layout safety: diff current SwapDepositRouter against the V1 snapshot.
        // Reverts with a descriptive error if any slot shifted, was removed/renamed, or an
        // unsafe pattern (selfdestruct, delegatecall, constructor state) was introduced.
        Options memory opts;
        opts.referenceContract = "SwapDepositRouterV1.sol:SwapDepositRouterV1";
        Upgrades.validateUpgrade("SwapDepositRouter.sol", opts);
        console.log("");
        console.log("Storage layout validated against V1 reference.");

        vm.startBroadcast();

        SwapDepositRouter newImpl = new SwapDepositRouter();
        console.log("New implementation deployed:", address(newImpl));

        proxy.upgradeToAndCall(address(newImpl), "");
        console.log("Proxy upgraded.");

        vm.stopBroadcast();

        // Post-upgrade state preservation
        require(address(proxy.poolManager()) == prevPoolManager, "poolManager changed");
        require(address(proxy.instrumentRegistry()) == prevInstrumentRegistry, "instrumentRegistry changed");
        require(address(proxy.swapPoolRegistry()) == prevSwapPoolRegistry, "swapPoolRegistry changed");
        require(Currency.unwrap(proxy.stable()) == prevStable, "stable changed");
        require(proxy.cctpBridge() == prevCctpBridge, "cctpBridge changed");
        require(proxy.cctpReceiver() == prevCctpReceiver, "cctpReceiver changed");
        require(proxy.owner() == prevOwner, "owner changed");

        // New impl is live: these calls revert if the upgrade silently no-op'd.
        require(proxy.protocolFeeBps() == 0, "protocolFeeBps must default to 0");
        require(proxy.feeRecipient() == address(0), "feeRecipient must default to address(0)");

        console.log("");
        console.log("=== Upgrade verified ===");
        console.log("");
        console.log("Next step: call setFeeConfig(protocolFeeBps, feeRecipient) from owner to enable fees.");
        console.log("If broadcast was run with --verify, the new implementation is auto-verified.");
        console.log("Otherwise verify manually with:");
        console.log("  FOUNDRY_PROFILE=deploy forge verify-contract <newImpl> \\");
        console.log("    src/SwapDepositRouter.sol:SwapDepositRouter --chain", block.chainid, "--watch");
    }
}
