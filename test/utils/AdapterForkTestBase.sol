// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AdapterForkTestBase
/// @notice Base contract for adapter fork tests with JSON config reading
/// @dev Reads config directly from JSON to avoid complex struct copying
abstract contract AdapterForkTestBase is Test {
    using stdJson for string;
    using CurrencyLibrary for Currency;

    string internal constant CONFIG_PATH = "script/config/NetworkConfig.json";

    string internal networkName;
    string internal json;
    string internal networkPath;

    address internal user;
    address internal recipient;

    uint256 internal constant DEPOSIT_AMOUNT = 1000e6; // 1k tokens (6 decimals)
    uint256 internal constant DEPOSIT_AMOUNT_18 = 1000e18; // 1k tokens (18 decimals)

    function setUp() public virtual {
        // Get network from environment or default
        networkName = vm.envOr("NETWORK", string("baseMainnet"));

        // Create and select fork
        _selectFork(networkName);

        // Load JSON config
        json = vm.readFile(CONFIG_PATH);
        networkPath = string.concat(".networks.", networkName);

        // Setup test addresses
        user = makeAddr("forkTestUser");
        recipient = makeAddr("forkTestRecipient");

        // Fund user with ETH for gas
        vm.deal(user, 100 ether);
        vm.deal(recipient, 100 ether);
    }

    // ============ Config Getters ============

    /// @notice Get token address by symbol (USDC, USDT, DAI, etc.)
    function getToken(string memory symbol) internal view returns (address) {
        string memory path = string.concat(networkPath, ".tokens.", symbol);
        if (!vm.keyExistsJson(json, path)) return address(0);
        return json.readAddress(path);
    }

    /// @notice Get Aave pool address
    function getAavePool() internal view returns (address) {
        return json.readAddress(string.concat(networkPath, ".protocols.aave.pool"));
    }

    /// @notice Get Compound comet address by name (usdcComet, usdbcComet, usdsComet)
    function getCompoundComet(string memory name) internal view returns (address) {
        string memory path = string.concat(networkPath, ".protocols.compound.", name);
        if (!vm.keyExistsJson(json, path)) return address(0);
        return json.readAddress(path);
    }

    /// @notice Get Morpho vault address by name
    function getMorphoVault(string memory name) internal view returns (address) {
        string memory path = string.concat(networkPath, ".protocols.morpho.vaults.", name);
        if (!vm.keyExistsJson(json, path)) return address(0);
        return json.readAddress(path);
    }

    /// @notice Get Euler Earn vault address by name
    function getEulerVault(string memory name) internal view returns (address) {
        string memory path = string.concat(networkPath, ".protocols.eulerEarn.vaults.", name);
        if (!vm.keyExistsJson(json, path)) return address(0);
        return json.readAddress(path);
    }

    /// @notice Get Fluid fToken address by name (fUSDC, fEURC, fGHO)
    function getFluidFToken(string memory name) internal view returns (address) {
        string memory path = string.concat(networkPath, ".protocols.fluid.fTokens.", name);
        if (!vm.keyExistsJson(json, path)) return address(0);
        return json.readAddress(path);
    }

    /// @notice Get deployed adapter address by name (aave, compound, morpho, fluid)
    function getDeployedAdapter(string memory name) internal view returns (address) {
        string memory path = string.concat(networkPath, ".deployed.adapters.", name);
        if (!vm.keyExistsJson(json, path)) return address(0);
        return json.readAddress(path);
    }

    // ============ Fork Helpers ============

    function _selectFork(string memory network) internal {
        string memory rpcEnvVar;
        bytes32 networkHash = keccak256(bytes(network));

        if (networkHash == keccak256("baseMainnet") || networkHash == keccak256("sandbox")) {
            rpcEnvVar = "BASE_RPC_URL";
        } else if (networkHash == keccak256("arbitrumMainnet")) {
            rpcEnvVar = "ARBITRUM_RPC_URL";
        } else {
            revert("Unsupported network for fork");
        }

        string memory rpcUrl = vm.envString(rpcEnvVar);
        vm.createSelectFork(rpcUrl);
    }

    // ============ Test Helpers ============

    function _dealTokens(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
    }

    function _approveTokens(address token, address from, address spender, uint256 amount) internal {
        vm.prank(from);
        IERC20(token).approve(spender, amount);
    }

    function _getBalance(address token, address account) internal view returns (uint256) {
        return IERC20(token).balanceOf(account);
    }

    function _computeMarketId(Currency currency) internal pure returns (bytes32) {
        return keccak256(abi.encode(currency));
    }

    function _computeMarketId(address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(Currency.wrap(token)));
    }

    function _computeVaultMarketId(address vault) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(vault)));
    }

    /// @notice Skip test if address is zero
    modifier skipIfZero(address addr) {
        if (addr == address(0)) return;
        _;
    }
}
