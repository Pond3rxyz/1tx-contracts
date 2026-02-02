// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ConfigReader, NetworkConfig, DeployedConfig} from "../../script/utils/ConfigReader.sol";

/// @title TestConfigReader
/// @notice Extends ConfigReader for use in tests with fork selection utilities
abstract contract TestConfigReader is ConfigReader, Test {
    /// @notice Creates and selects a fork for the specified network
    /// @param network The network name (e.g., "baseMainnet", "arbitrumMainnet")
    function _selectFork(string memory network) internal {
        string memory rpcEnvVar = _getRpcEnvVar(network);
        string memory rpcUrl = vm.envString(rpcEnvVar);
        vm.createSelectFork(rpcUrl);
    }

    /// @notice Creates and selects a fork at a specific block
    /// @param network The network name
    /// @param blockNumber The block number to fork at
    function _selectForkAtBlock(string memory network, uint256 blockNumber) internal {
        string memory rpcEnvVar = _getRpcEnvVar(network);
        string memory rpcUrl = vm.envString(rpcEnvVar);
        vm.createSelectFork(rpcUrl, blockNumber);
    }

    /// @notice Gets the environment variable name for RPC URL
    function _getRpcEnvVar(string memory network) internal pure returns (string memory) {
        bytes32 networkHash = keccak256(bytes(network));

        if (networkHash == keccak256("baseMainnet")) {
            return "BASE_RPC_URL";
        } else if (networkHash == keccak256("arbitrumMainnet")) {
            return "ARBITRUM_RPC_URL";
        } else if (networkHash == keccak256("sandbox")) {
            return "BASE_RPC_URL"; // Sandbox uses Base mainnet state
        } else {
            revert("Unsupported network for fork");
        }
    }

    /// @notice Gets network config from environment or defaults to Base mainnet
    function _getNetworkFromEnv() internal view returns (string memory) {
        return vm.envOr("NETWORK", string("baseMainnet"));
    }

    /// @notice Helper to get token address by symbol from config
    function _getTokenAddress(NetworkConfig memory config, string memory symbol) internal pure returns (address) {
        bytes32 symbolHash = keccak256(bytes(symbol));

        if (symbolHash == keccak256("USDC")) return config.tokens.USDC;
        if (symbolHash == keccak256("USDT")) return config.tokens.USDT;
        if (symbolHash == keccak256("DAI")) return config.tokens.DAI;
        if (symbolHash == keccak256("EURC")) return config.tokens.EURC;
        if (symbolHash == keccak256("USDbC")) return config.tokens.USDbC;
        if (symbolHash == keccak256("GHO")) return config.tokens.GHO;
        if (symbolHash == keccak256("USDS")) return config.tokens.USDS;
        if (symbolHash == keccak256("eUSD")) return config.tokens.eUSD;
        if (symbolHash == keccak256("WETH")) return config.tokens.WETH;
        if (symbolHash == keccak256("cbBTC")) return config.tokens.cbBTC;

        return address(0);
    }

    /// @notice Deals tokens to an address (uses Foundry's deal cheatcode)
    function _dealTokens(address token, address to, uint256 amount) internal virtual {
        deal(token, to, amount);
    }
}
