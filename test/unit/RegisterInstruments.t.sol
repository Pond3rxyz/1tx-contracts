// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {RegisterInstruments} from "../../script/RegisterInstruments.s.sol";

/// @title RegisterInstrumentsSelectionTest
/// @notice How `RegisterInstruments` tells its two listing shapes apart, tested against fixture
///         JSON.
///
/// @dev The script registers both ERC-4626 vault lists and Aave-shaped reserve lists, and picks
///      the branch from the config block's own keys: **both** `pool` and `reserves` means
///      Aave-shaped. That rule is what decides, silently, whether a newly configured Aave fork is
///      listed or ignored on the next run, so it is worth a test that does not need a fork.
///
///      Fixtures are JSON **strings**, not files: `foundry.toml` grants read access to
///      `script/config/` only, and a rule tested against the real config can only ever assert what
///      the real config happens to contain today.
contract RegisterInstrumentsSelectionTest is Test {
    RegisterInstruments internal script_;

    string internal constant NET = ".networks.testnet";

    function setUp() public {
        script_ = new RegisterInstruments();
    }

    function _select(string memory json) internal view returns (string[] memory) {
        return script_.reserveShapedProtocols(json, NET);
    }

    /// @notice Both keys present: selected.
    function test_selectsProtocolWithPoolAndReserves() public view {
        string memory json = '{"networks":{"testnet":{"protocols":{'
            '"aave":{"pool":"0x0000000000000000000000000000000000000001","reserves":["USDC"]}' "}}}}";

        string[] memory selected = _select(json);
        assertEq(selected.length, 1, "aave was not selected");
        assertEq(selected[0], "aave");
    }

    /// @notice A vault-list protocol is `RegisterInstruments`'s business and drops out here.
    /// @dev Including one that carries an `adapter` block, because `neverland` does too — the
    ///      `adapter` block is not what distinguishes the two scripts' territory.
    function test_ignoresVaultShapedProtocols() public view {
        string memory json = '{"networks":{"testnet":{"protocols":{'
            '"morpho":{"adapter":{"key":"morpho","name":"Morpho Vaults V2"},"vaults":{"a":"0x0000000000000000000000000000000000000002"}},'
            '"fluid":{"liquidity":"0x0000000000000000000000000000000000000003","fTokens":{"fUSDC":"0x0000000000000000000000000000000000000004"}}'
            "}}}}";

        assertEq(_select(json).length, 0, "a vault-shaped protocol was selected");
    }

    /// @notice `pool` alone is not enough. Compound's config carries pool-ish addresses and no
    ///         enumerable reserve list; selecting it would try to register Comets as Aave markets.
    function test_ignoresPoolWithoutReserves() public view {
        string memory json = '{"networks":{"testnet":{"protocols":{'
            '"aave":{"pool":"0x0000000000000000000000000000000000000001"}' "}}}}";

        assertEq(_select(json).length, 0, "a protocol with no reserve list was selected");
    }

    /// @notice And `reserves` alone is not enough: with no pool there is nothing to read
    ///         `getReserveData` from, and nothing to register the instrument against.
    function test_ignoresReservesWithoutPool() public view {
        string memory json = '{"networks":{"testnet":{"protocols":{' '"aave":{"reserves":["USDC"]}' "}}}}";

        assertEq(_select(json).length, 0, "a protocol with no pool was selected");
    }

    /// @notice The shape this script was written for: Aave and an Aave fork side by side, both
    ///         selected, in config order.
    function test_selectsBothAaveAndAFork() public view {
        string memory json = '{"networks":{"testnet":{"protocols":{'
            '"aave":{"pool":"0x0000000000000000000000000000000000000001","reserves":["USDC","GHO"]},'
            '"morpho":{"adapter":{"key":"morpho","name":"Morpho"},"vaults":{"a":"0x0000000000000000000000000000000000000002"}},'
            '"neverland":{"adapter":{"key":"neverland","name":"Neverland"},"pool":"0x0000000000000000000000000000000000000005","reserves":["USDC","AUSD"]}'
            "}}}}";

        string[] memory selected = _select(json);
        assertEq(selected.length, 2, "expected exactly aave and neverland");
        assertEq(selected[0], "aave");
        assertEq(selected[1], "neverland");
    }

    /// @notice A network with no `protocols` block returns empty rather than reverting — the
    ///         script prints "nothing configured" and exits, which is the behaviour a chain that
    ///         lists no reserves needs.
    function test_missingProtocolsBlockIsEmptyNotAnError() public view {
        assertEq(
            _select('{"networks":{"testnet":{"tokens":{"USDC":"0x0000000000000000000000000000000000000001"}}}}').length,
            0
        );
    }

    /// @notice An empty `protocols` block likewise.
    function test_emptyProtocolsBlockIsEmpty() public view {
        assertEq(_select('{"networks":{"testnet":{"protocols":{}}}}').length, 0);
    }

    // ============================================
    // And against the config the script actually reads
    // ============================================

    /// @notice Monad's real config selects exactly `aave` and `neverland`.
    /// @dev The fixtures above pin the rule; this pins that the rule and the live config agree, so
    ///      a `neverland` block that is added without both keys fails here rather than on a dry
    ///      run that reads clean and registers nothing.
    function test_monadConfigSelectsAaveAndNeverland() public view {
        string memory config = vm.readFile("script/config/NetworkConfig.json");
        string[] memory selected = script_.reserveShapedProtocols(config, ".networks.monadMainnet");

        assertEq(selected.length, 2, "Monad no longer selects exactly two reserve-shaped protocols");
        assertEq(selected[0], "aave");
        assertEq(selected[1], "neverland");
    }

    /// @notice The chains that were deployed before the fork existed still select `aave` alone.
    /// @dev Guards the blast radius: this script is additive on every chain, and a rule that
    ///      accidentally widened would try to register markets on Base, Arbitrum and Unichain too.
    function test_otherChainsSelectAaveOnly() public view {
        string memory config = vm.readFile("script/config/NetworkConfig.json");
        string[3] memory networks = ["baseMainnet", "arbitrumMainnet", "unichainMainnet"];

        for (uint256 i = 0; i < networks.length; i++) {
            string[] memory selected = script_.reserveShapedProtocols(config, string.concat(".networks.", networks[i]));
            for (uint256 j = 0; j < selected.length; j++) {
                assertEq(selected[j], "aave", string.concat("unexpected reserve-shaped protocol on ", networks[i]));
            }
        }
    }
}
