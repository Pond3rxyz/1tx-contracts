// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {
    ConfigReader,
    NetworkConfig,
    DeployedConfig,
    CCTPConfig,
    CCTPDestination
} from "../../script/utils/ConfigReader.sol";

/// @title NetworkConfigTest
/// @notice Guards the invariants of `script/config/NetworkConfig.json` that a deploy script would
///         otherwise discover at broadcast time, against live production, one owner-call too late.
///
/// @dev The CCTP mesh tests exist because the failure they catch is silent and expensive. A
///      destination carrying the wrong `domain` does not revert on configuration — it reverts (or
///      worse, mints somewhere unintended) on the first user bridge. Deriving each expected value
///      from the *destination chain's own* config block, rather than restating it, means a typo
///      has to be made identically in two places to survive.
contract NetworkConfigTest is Test, ConfigReader {
    /// @dev Every chain the protocol treats as production. Adding a chain here without wiring it
    ///      into the mesh fails `test_cctpMeshIsComplete`.
    string[] internal mainnets;

    function setUp() public {
        mainnets.push("baseMainnet");
        mainnets.push("arbitrumMainnet");
        mainnets.push("unichainMainnet");
        mainnets.push("monadMainnet");
    }

    // ============================================
    // Network detection
    // ============================================

    function test_detectNetworkFromChainId_coversEveryMainnet() public view {
        for (uint256 i = 0; i < mainnets.length; i++) {
            NetworkConfig memory config = getNetworkConfig(mainnets[i]);
            assertEq(
                detectNetworkFromChainId(config.chainId),
                mainnets[i],
                string.concat("chainId does not round-trip for ", mainnets[i])
            );
        }
    }

    function test_detectNetworkFromChainId_monad() public pure {
        assertEq(detectNetworkFromChainId(143), "monadMainnet");
    }

    function test_detectNetworkFromChainId_revertsOnUnknown() public {
        vm.expectRevert("Unsupported network");
        this.exposed_detectNetwork(999999);
    }

    function exposed_detectNetwork(uint256 chainId) external pure returns (string memory) {
        return detectNetworkFromChainId(chainId);
    }

    // ============================================
    // Per-network completeness
    // ============================================

    /// @dev `Deploy.s.sol:_validateNetwork` requires exactly these three. A chain missing the
    ///      PoolManager reverts `InvalidPoolManager()` inside `SwapDepositRouter.initialize` —
    ///      mandatory even for a chain listing only USDC-native instruments, where no swap can
    ///      ever fire.
    function test_everyMainnetSatisfiesDeployPreconditions() public view {
        for (uint256 i = 0; i < mainnets.length; i++) {
            NetworkConfig memory config = getNetworkConfig(mainnets[i]);
            assertTrue(config.chainId != 0, string.concat("chainId unset: ", mainnets[i]));
            assertTrue(config.uniswapV4.poolManager != address(0), string.concat("poolManager unset: ", mainnets[i]));
            assertTrue(config.tokens.USDC != address(0), string.concat("USDC unset: ", mainnets[i]));
        }
    }

    /// @dev `getDeployedConfig` reads `instrumentToken`, `swapDepositorHook` and
    ///      `adapters.{aave,compound,morpho,fluid}` with `readAddress`, which reverts on a missing
    ///      key rather than defaulting. A new chain that legitimately has no Compound and no Fluid
    ///      still needs those keys present as the zero address, and forgetting them breaks every
    ///      script that reads the deployed block — not just the ones that use those adapters.
    function test_everyMainnetDeployedBlockIsReadable() public view {
        for (uint256 i = 0; i < mainnets.length; i++) {
            getDeployedConfig(mainnets[i]);
        }
    }

    // ============================================
    // CCTP mesh
    // ============================================

    /// @dev Outbound CCTP wiring is pairwise: n(n-1) directed edges. The cost of adding chain #4
    ///      is not the new chain's own configuration, it is remembering to add the new destination
    ///      to the three chains that already exist. This is the test for that.
    function test_cctpMeshIsComplete() public view {
        for (uint256 i = 0; i < mainnets.length; i++) {
            CCTPConfig memory source = getCCTPConfig(mainnets[i]);

            for (uint256 j = 0; j < mainnets.length; j++) {
                if (i == j) continue;
                NetworkConfig memory targetNet = getNetworkConfig(mainnets[j]);

                bool found;
                for (uint256 k = 0; k < source.destinations.length; k++) {
                    if (source.destinations[k].chainId == uint32(targetNet.chainId)) {
                        found = true;
                        break;
                    }
                }
                assertTrue(found, string.concat("missing CCTP destination on ", mainnets[i], " for ", mainnets[j]));
            }
        }
    }

    /// @dev Each destination's `domain` must equal the destination chain's own `cctp.domain`, and
    ///      its `receiver` must equal that chain's own `deployed.cctpReceiver`. Both are derived
    ///      from the far side rather than asserted as literals, so a copy-paste that points Monad
    ///      at Unichain's receiver fails here instead of sending USDC to a contract on the wrong
    ///      chain, recoverable only by that receiver's owner.
    function test_cctpDestinationsAgreeWithTheirTargetChain() public view {
        for (uint256 i = 0; i < mainnets.length; i++) {
            CCTPConfig memory source = getCCTPConfig(mainnets[i]);

            for (uint256 k = 0; k < source.destinations.length; k++) {
                CCTPDestination memory dest = source.destinations[k];
                string memory targetName = detectNetworkFromChainId(dest.chainId);

                CCTPConfig memory target = getCCTPConfig(targetName);
                assertEq(
                    uint256(dest.domain),
                    uint256(target.domain),
                    string.concat("domain mismatch: ", mainnets[i], " -> ", targetName)
                );

                DeployedConfig memory targetDeployed = getDeployedConfig(targetName);
                assertEq(
                    dest.receiver,
                    targetDeployed.cctp.cctpReceiver,
                    string.concat("receiver mismatch: ", mainnets[i], " -> ", targetName)
                );
            }
        }
    }

    /// @dev CCTP domain 0 is Ethereum, so "domain == 0" cannot mean "unset". `configuredDomains`
    ///      is the flag that distinguishes them on-chain; here the guard is that no chain claims
    ///      domain 0 until Ethereum is actually deployed, which would make the two indistinguishable
    ///      in config review.
    function test_noMainnetClaimsDomainZero() public view {
        for (uint256 i = 0; i < mainnets.length; i++) {
            CCTPConfig memory cctp = getCCTPConfig(mainnets[i]);
            assertTrue(cctp.tokenMessenger != address(0), string.concat("tokenMessenger unset: ", mainnets[i]));
            assertTrue(cctp.messageTransmitter != address(0), string.concat("messageTransmitter unset: ", mainnets[i]));
            assertTrue(cctp.domain != 0, string.concat("domain 0 is Ethereum: ", mainnets[i]));
        }
    }

    // ============================================
    // Monad specifics
    // ============================================

    function test_monadConfigMatchesChainState() public view {
        NetworkConfig memory config = getNetworkConfig("monadMainnet");
        CCTPConfig memory cctp = getCCTPConfig("monadMainnet");

        // Verified live against rpc.monad.xyz: eth_chainId and MessageTransmitter.localDomain().
        assertEq(config.chainId, 143);
        assertEq(uint256(cctp.domain), 15);
        assertEq(config.tokens.USDC, 0x754704Bc059F8C67012fEd69BC8A327a5aafb603);
        assertEq(config.uniswapV4.poolManager, 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e);
    }

    /// @dev Monad launches USDC-native only, so it registers no swap pools. `_countSwapPools`
    ///      walks `swapPools[i]` until the key is absent, and an empty array has to survive that
    ///      walk rather than reverting.
    function test_monadHasNoSwapPools() public view {
        NetworkConfig memory config = getNetworkConfig("monadMainnet");
        assertEq(config.swapPools.length, 0);
    }

    // ============================================
    // Token + Aave reserve resolution
    // ============================================

    /// @dev The generalised lookup must agree with the struct field for every symbol the struct
    ///      still carries — this is what makes replacing the hardcoded table in
    ///      `Deploy.s.sol:_getTokenAddress` a no-op for the three live chains.
    function test_getTokenAddressBySymbol_agreesWithStruct() public view {
        for (uint256 i = 0; i < mainnets.length; i++) {
            NetworkConfig memory config = getNetworkConfig(mainnets[i]);
            assertEq(getTokenAddressBySymbol(mainnets[i], "USDC"), config.tokens.USDC);
            assertEq(getTokenAddressBySymbol(mainnets[i], "USDT"), config.tokens.USDT);
            assertEq(getTokenAddressBySymbol(mainnets[i], "GHO"), config.tokens.GHO);
            assertEq(getTokenAddressBySymbol(mainnets[i], "WETH"), config.tokens.WETH);
        }
    }

    function test_getTokenAddressBySymbol_unknownSymbolIsZero() public view {
        assertEq(getTokenAddressBySymbol("baseMainnet", "NOT_A_TOKEN"), address(0));
    }

    /// @dev Absent `protocols.aave.reserves`, the fallback must reproduce the exact symbol list
    ///      `Deploy.s.sol` used to hardcode, or a redeploy of a live chain would register a
    ///      different market set than the one in production.
    function test_getAaveReserveSymbols_fallbackIsTheHistoricalList() public view {
        string[] memory symbols = getAaveReserveSymbols("baseMainnet");
        assertEq(symbols.length, 8);
        assertEq(symbols[0], "USDC");
        assertEq(symbols[1], "USDT");
        assertEq(symbols[2], "DAI");
        assertEq(symbols[3], "EURC");
        assertEq(symbols[4], "USDbC");
        assertEq(symbols[5], "GHO");
        assertEq(symbols[6], "USDS");
        assertEq(symbols[7], "cbBTC");
    }

    function test_getAaveReserveSymbols_configOverrides() public view {
        string[] memory symbols = getAaveReserveSymbols("monadMainnet");
        assertEq(symbols.length, 1);
        assertEq(symbols[0], "USDC");
    }

    /// @dev Every symbol named as an Aave reserve has to resolve in the `tokens` map, or
    ///      `_registerAaveStablecoin` skips it on address(0) and the market is silently missing —
    ///      with no additive script to add it afterwards.
    function test_aaveReserveSymbolsResolveToTokens() public view {
        for (uint256 i = 0; i < mainnets.length; i++) {
            NetworkConfig memory config = getNetworkConfig(mainnets[i]);
            if (config.protocols.aave.pool == address(0)) continue;

            string[] memory symbols = getAaveReserveSymbols(mainnets[i]);
            bool anyResolved;
            for (uint256 k = 0; k < symbols.length; k++) {
                if (getTokenAddressBySymbol(mainnets[i], symbols[k]) != address(0)) anyResolved = true;
            }
            assertTrue(anyResolved, string.concat("no Aave reserve symbol resolves on ", mainnets[i]));
        }
    }

    // ============================================
    // Vault list integrity
    // ============================================

    /// @dev The two market-map key names `RegisterInstruments` reads. Fluid calls its map
    ///      `fTokens`; everyone else calls it `vaults`.
    string[2] internal LIST_KEYS = ["vaults", "fTokens"];

    /// @notice No two config entries on one network may point at the same vault.
    /// @dev `InstrumentIdLib` keys on the vault address, so a duplicated address is not two
    ///      instruments — it is one, and `RegisterInstruments._registerVault` skips the second
    ///      copy with `SKIP (exists)` while the config still advertises both. The hazard is
    ///      concrete: Morpho ships same-*named* vaults in two generations (Moonwell Flagship USDC
    ///      exists as MetaMorpho V1.1 at `0xc1256Ae5` holding $9.77M and as Vaults V2 at
    ///      `0x48a90E85` holding $10k, both minting `mwUSDC`), so a copy-paste while adding one
    ///      generation silently overwrites the other. Cheap to assert, invisible otherwise.
    function test_noNetworkListsOneVaultTwice() public view {
        string memory json = vm.readFile(CONFIG_PATH);

        for (uint256 i = 0; i < mainnets.length; i++) {
            string memory protocolsPath = string.concat(".networks.", mainnets[i], ".protocols");
            if (!vm.keyExistsJson(json, protocolsPath)) continue;

            string[] memory protocols = vm.parseJsonKeys(json, protocolsPath);
            address[] memory seen = new address[](256);
            string[] memory seenKeys = new string[](256);
            uint256 count;

            for (uint256 p = 0; p < protocols.length; p++) {
                for (uint256 k = 0; k < LIST_KEYS.length; k++) {
                    string memory listPath = string.concat(protocolsPath, ".", protocols[p], ".", LIST_KEYS[k]);
                    if (!vm.keyExistsJson(json, listPath)) continue;

                    string[] memory names = vm.parseJsonKeys(json, listPath);
                    for (uint256 n = 0; n < names.length; n++) {
                        address vault = vm.parseJsonAddress(json, string.concat(listPath, ".", names[n]));
                        assertTrue(
                            vault != address(0), string.concat("zero vault address: ", mainnets[i], ".", names[n])
                        );

                        for (uint256 s = 0; s < count; s++) {
                            assertTrue(
                                seen[s] != vault,
                                string.concat(
                                    "duplicate vault address on ", mainnets[i], ": ", seenKeys[s], " and ", names[n]
                                )
                            );
                        }

                        seen[count] = vault;
                        seenKeys[count] = names[n];
                        count++;
                    }
                }
            }
        }
    }
}
