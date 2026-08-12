// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {CCTPBridge} from "../../src/CCTPBridge.sol";
import {SwapDepositRouter} from "../../src/SwapDepositRouter.sol";
import {TestConfigReader} from "./TestConfigReader.sol";
import {DeployedConfig, CCTPConfig, CCTPDestination} from "../../script/utils/ConfigReader.sol";

/// @title CCTPWiringForkTest
/// @notice Shared body for the per-chain CCTP wiring fork tests.
///
/// @dev This is the read half of `AddCCTPDestinations.s.sol`, run against live state as a test.
///      It asserts the precondition that makes that script safe to point at production: for every
///      destination already in service, config and chain agree, so the script has nothing to write
///      and cannot repoint anything by accident. Every mainnet destination is now live, so this
///      covers the whole mesh; while Monad was mid-onboarding it also asserted chain 143 was
///      genuinely unwired, which is what made adding that edge safe.
///
///      Executing the script here instead would need the fork's bridge ownership transferred to
///      the script contract, since `vm.prank` does not propagate through the script's own calls
///      into the bridge. That buys little: what can actually be wrong is the config, and this
///      checks the config against the only authority on the subject.
abstract contract CCTPWiringForkTest is TestConfigReader {
    CCTPBridge internal bridge;
    SwapDepositRouter internal router;
    string internal network;

    function _initWiringTest(string memory networkName) internal {
        network = networkName;
        _selectFork(networkName);

        DeployedConfig memory deployed = getDeployedConfig(networkName);
        bridge = CCTPBridge(deployed.cctp.cctpBridge);
        router = SwapDepositRouter(deployed.swapDepositorRouter);

        assertTrue(address(bridge) != address(0), "cctpBridge missing from config");
        assertTrue(address(router) != address(0), "router missing from config");
    }

    /// @notice The same-chain wiring `AddCCTPDestinations._bootstrap` would otherwise write.
    function test_sameChainWiringIsAlreadyCorrect() public view {
        CCTPConfig memory cctp = getCCTPConfig(network);
        assertEq(bridge.tokenMessenger(), cctp.tokenMessenger, "bridge.tokenMessenger drifted from config");
        assertTrue(bridge.authorizedCallers(address(router)), "router not authorized on bridge");
        assertEq(router.cctpBridge(), address(bridge), "router.cctpBridge drifted from config");
    }

    /// @notice Live destinations match config exactly, so an additive run writes nothing for them.
    /// @dev This is the acceptance test from the chain-onboarding plan, stated as a precondition:
    ///      re-running with no config change must produce zero transactions.
    function test_liveDestinationsMatchConfig() public view {
        CCTPConfig memory cctp = getCCTPConfig(network);
        uint256 checked;

        for (uint256 i = 0; i < cctp.destinations.length; i++) {
            CCTPDestination memory dest = cctp.destinations[i];

            assertTrue(bridge.configuredDomains(dest.chainId), "destination not configured on-chain");
            assertEq(uint256(bridge.chainIdToCCTPDomain(dest.chainId)), uint256(dest.domain), "domain drift");

            bytes32 expected = bytes32(uint256(uint160(dest.receiver)));
            assertEq(bridge.chainIdToMintRecipient(dest.chainId), expected, "mintRecipient drift");
            assertEq(bridge.chainIdToDestinationCaller(dest.chainId), expected, "destinationCaller drift");
            checked++;
        }

        assertTrue(checked > 0, "no live destinations checked");
    }
}
