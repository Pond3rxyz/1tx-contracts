// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/console.sol";

import {SwapDepositRouter} from "../src/SwapDepositRouter.sol";
import {CCTPBridge} from "../src/CCTPBridge.sol";
import {ConfigReader, DeployedConfig, CCTPConfig, CCTPDestination} from "./utils/ConfigReader.sol";

/// @title AddCCTPDestinations
/// @notice Adds CCTP destinations to a live `CCTPBridge` without touching the ones already wired.
///
/// @dev **Use this, not `ConfigureCCTP.s.sol`, on a chain that is already in production.**
///      `ConfigureCCTP` is a full rewrite: it unconditionally re-issues `setTokenMessenger`,
///      `setAuthorizedCaller`, `router.setCCTPBridge`, `router.setCCTPReceiver`, and then loops
///      *every* destination calling all three setters. Adding one edge to Base today costs ~10
///      redundant owner-only writes against live production, with no skip, no diff and no
///      assertion that the result is what config says. That is fine for a first deploy and wrong
///      for an incremental one.
///
///      This script diffs first. Every piece of state it needs is already a public getter:
///
///      ```
///      bridge.configuredDomains(chainId)          bridge.chainIdToCCTPDomain(chainId)
///      bridge.chainIdToMintRecipient(chainId)     bridge.chainIdToDestinationCaller(chainId)
///      bridge.authorizedCallers(addr)             bridge.tokenMessenger()
///      router.cctpBridge()                        router.cctpReceiver()
///      ```
///
///      Per destination:
///        - all three values match config           -> `SKIP (exists)`, zero transactions
///        - unset                                   -> write only what is unset, log `SET`
///        - set to something else                   -> **abort**, printing old and new
///
///      The mismatch case aborts by default rather than overwriting because a silently repointed
///      `mintRecipient` sends bridged USDC to the wrong contract on the far side, where only the
///      receiver's owner can rescue it. Repointing is deliberate work, so it lives behind a
///      separate entry point:
///
///      ```
///      forge script script/AddCCTPDestinations.s.sol:AddCCTPDestinations --sig "runForce()" ...
///      ```
///
///      A destination whose `receiver` is still the zero address in config is *not* an error: the
///      far-side `CCTPReceiver` has not been deployed yet. Its domain is written (that value is a
///      Circle constant and always known) and the recipient/caller pair is deferred. Re-run after
///      writing the receiver address back into config.
///
/// Usage (dry run — always do this first, it prints the exact diff):
///   forge script script/AddCCTPDestinations.s.sol:AddCCTPDestinations --rpc-url <network> \
///     --sender 0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73 -vvvv
///
/// Broadcast (signer MUST own the CCTPBridge and the SwapDepositRouter):
///   forge script script/AddCCTPDestinations.s.sol:AddCCTPDestinations --rpc-url <network> \
///     --account <keystore> --sender 0x4d0e3d2759B8f96B4FA82b2c308Dcd7663794F73 --broadcast -vvvv
///
/// Acceptance test: re-running with no config change must produce zero transactions.
contract AddCCTPDestinations is ConfigReader {
    CCTPBridge public bridge;
    SwapDepositRouter public router;
    address public receiver;

    /// @dev Set by {runForce}. Turns the abort-on-mismatch into an overwrite.
    bool public force;

    uint256 public writes;
    uint256 public skips;
    uint256 public deferred;

    /// @notice Additive run. Aborts if config disagrees with a value already set on-chain.
    function run() external {
        _run();
    }

    /// @notice Repointing run. Overwrites destinations that are already set to a different value.
    /// @dev Separate entry point on purpose — see the contract-level note on `mintRecipient`.
    function runForce() external {
        force = true;
        console.log("!! FORCE MODE - existing destinations will be OVERWRITTEN !!");
        _run();
    }

    function _run() internal {
        string memory networkName = detectNetworkFromChainId(block.chainid);
        DeployedConfig memory deployed = getDeployedConfig(networkName);
        CCTPConfig memory cctp = getCCTPConfig(networkName);

        bridge = CCTPBridge(deployed.cctp.cctpBridge);
        router = SwapDepositRouter(deployed.swapDepositorRouter);
        receiver = deployed.cctp.cctpReceiver;

        require(address(bridge) != address(0), "cctpBridge missing from config");
        require(address(router) != address(0), "swapDepositorRouter missing from config");
        require(cctp.tokenMessenger != address(0), "cctp.tokenMessenger missing from config");

        console.log("\n================================================");
        console.log("  Add CCTP Destinations");
        console.log("================================================");
        console.log("Network:     ", networkName);
        console.log("Chain ID:    ", block.chainid);
        console.log("CCTPBridge:  ", address(bridge));
        console.log("Router:      ", address(router));
        console.log("CCTPReceiver:", receiver);

        vm.startBroadcast();
        _bootstrap(cctp.tokenMessenger);
        for (uint256 i = 0; i < cctp.destinations.length; i++) {
            _addDestination(cctp.destinations[i]);
        }
        vm.stopBroadcast();

        _verify(cctp);

        console.log("\n--- Summary ---");
        console.log("  Writes:  ", writes);
        console.log("  Skipped: ", skips);
        console.log("  Deferred (receiver not deployed):", deferred);
        console.log("================================================\n");
    }

    /// @notice Same-chain wiring, written only where it is missing.
    /// @dev On a freshly deployed chain `Deploy.s.sol` has already done all of this, so the normal
    ///      outcome here is four skips. It is repeated rather than assumed because a bridge with
    ///      no `tokenMessenger`, or one the router is not authorized to call, fails at the first
    ///      user bridge rather than at deploy time.
    function _bootstrap(address tokenMessenger) internal {
        console.log("\n--- Same-chain wiring ---");

        if (bridge.tokenMessenger() == tokenMessenger) {
            console.log("  SKIP (exists): bridge.tokenMessenger");
            skips++;
        } else if (bridge.tokenMessenger() == address(0)) {
            bridge.setTokenMessenger(tokenMessenger);
            console.log("  SET: bridge.tokenMessenger =", tokenMessenger);
            writes++;
        } else {
            console.log("  MISMATCH bridge.tokenMessenger");
            console.log("    on-chain:", bridge.tokenMessenger());
            console.log("    config:  ", tokenMessenger);
            require(force, "tokenMessenger mismatch; re-run with --sig runForce() to overwrite");
            bridge.setTokenMessenger(tokenMessenger);
            console.log("    FORCED");
            writes++;
        }

        if (bridge.authorizedCallers(address(router))) {
            console.log("  SKIP (exists): bridge.authorizedCallers[router]");
            skips++;
        } else {
            bridge.setAuthorizedCaller(address(router), true);
            console.log("  SET: bridge.authorizedCallers[router] = true");
            writes++;
        }

        if (router.cctpBridge() == address(bridge)) {
            console.log("  SKIP (exists): router.cctpBridge");
            skips++;
        } else {
            router.setCCTPBridge(address(bridge));
            console.log("  SET: router.cctpBridge =", address(bridge));
            writes++;
        }

        if (receiver == address(0)) {
            console.log("  WARN: cctpReceiver not in config; router.cctpReceiver left as-is");
        } else if (router.cctpReceiver() == receiver) {
            console.log("  SKIP (exists): router.cctpReceiver");
            skips++;
        } else {
            router.setCCTPReceiver(receiver);
            console.log("  SET: router.cctpReceiver =", receiver);
            writes++;
        }
    }

    function _addDestination(CCTPDestination memory dest) internal {
        console.log(string.concat("\n--- destination: ", dest.name, " ---"));
        console.log("  chainId:", uint256(dest.chainId), " domain:", uint256(dest.domain));

        _setDomain(dest);

        // The far-side receiver may not exist yet. Its domain is a Circle constant and safe to
        // write now; the recipient and caller are not, so they wait for a re-run.
        if (dest.receiver == address(0)) {
            console.log("  DEFERRED: receiver is 0x0 in config (far-side not deployed yet)");
            console.log("    -> deploy there, write the CCTPReceiver into config, re-run this script");
            deferred++;
            return;
        }

        bytes32 expected = bytes32(uint256(uint160(dest.receiver)));
        _setBytes32("mintRecipient", dest.chainId, expected, true);
        _setBytes32("destinationCaller", dest.chainId, expected, false);
    }

    /// @dev `configuredDomains` is what distinguishes "unset" from "set to 0" — Ethereum's CCTP
    ///      domain *is* 0, so the domain value alone cannot tell those apart.
    function _setDomain(CCTPDestination memory dest) internal {
        if (!bridge.configuredDomains(dest.chainId)) {
            bridge.setDestinationDomain(dest.chainId, dest.domain);
            console.log("  SET: domain =", uint256(dest.domain));
            writes++;
            return;
        }

        uint32 onChain = bridge.chainIdToCCTPDomain(dest.chainId);
        if (onChain == dest.domain) {
            console.log("  SKIP (exists): domain");
            skips++;
            return;
        }

        console.log("  MISMATCH domain");
        console.log("    on-chain:", uint256(onChain));
        console.log("    config:  ", uint256(dest.domain));
        require(force, "domain mismatch; re-run with --sig runForce() to overwrite");
        bridge.setDestinationDomain(dest.chainId, dest.domain);
        console.log("    FORCED");
        writes++;
    }

    /// @param isMintRecipient selects the setter — true for `mintRecipient`, false for
    ///        `destinationCaller`. The two are written to the same value (the far-side receiver)
    ///        but are independent storage slots, so each is diffed on its own.
    function _setBytes32(string memory label, uint32 chainId, bytes32 expected, bool isMintRecipient) internal {
        bytes32 onChain =
            isMintRecipient ? bridge.chainIdToMintRecipient(chainId) : bridge.chainIdToDestinationCaller(chainId);

        if (onChain == expected) {
            console.log(string.concat("  SKIP (exists): ", label));
            skips++;
            return;
        }
        if (onChain == bytes32(0)) {
            _write(chainId, expected, isMintRecipient);
            console.log(string.concat("  SET: ", label, " ="), vm.toString(expected));
            writes++;
            return;
        }

        console.log(string.concat("  MISMATCH ", label));
        console.log("    on-chain:", vm.toString(onChain));
        console.log("    config:  ", vm.toString(expected));
        require(force, string.concat(label, " mismatch; re-run with --sig runForce() to overwrite"));
        _write(chainId, expected, isMintRecipient);
        console.log("    FORCED");
        writes++;
    }

    function _write(uint32 chainId, bytes32 value, bool isMintRecipient) internal {
        if (isMintRecipient) {
            bridge.setDestinationMintRecipient(chainId, value);
        } else {
            bridge.setDestinationCaller(chainId, value);
        }
    }

    /// @notice Re-reads every value after broadcast and reverts if it is not what config asked for.
    /// @dev Mirrors {RegisterInstruments}, which asserts `authorizedCallers` rather than assuming
    ///      the write landed. A broadcast that reverted mid-flight otherwise reads as a success.
    function _verify(CCTPConfig memory cctp) internal view {
        require(bridge.tokenMessenger() == cctp.tokenMessenger, "post: tokenMessenger");
        require(bridge.authorizedCallers(address(router)), "post: router not authorized on bridge");
        require(router.cctpBridge() == address(bridge), "post: router.cctpBridge");
        if (receiver != address(0)) {
            require(router.cctpReceiver() == receiver, "post: router.cctpReceiver");
        }

        for (uint256 i = 0; i < cctp.destinations.length; i++) {
            CCTPDestination memory dest = cctp.destinations[i];
            require(bridge.configuredDomains(dest.chainId), "post: domain not configured");
            require(bridge.chainIdToCCTPDomain(dest.chainId) == dest.domain, "post: domain");
            if (dest.receiver == address(0)) continue;

            bytes32 expected = bytes32(uint256(uint160(dest.receiver)));
            require(bridge.chainIdToMintRecipient(dest.chainId) == expected, "post: mintRecipient");
            require(bridge.chainIdToDestinationCaller(dest.chainId) == expected, "post: destinationCaller");
        }
    }
}
