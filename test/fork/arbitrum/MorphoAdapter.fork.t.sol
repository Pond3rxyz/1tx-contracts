// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @title MorphoAdapterArbitrumForkTest
/// @notice Fork tests for MorphoAdapter against Arbitrum mainnet
contract MorphoAdapterArbitrumForkTest is AdapterForkTestBase {
    MorphoAdapter public adapter;

    function setUp() public override {
        // Override network to Arbitrum
        networkName = "arbitrumMainnet";
        super.setUp();

        adapter = new MorphoAdapter(address(this));
    }

    // ============ Vault Tests ============

    function test_fork_arbitrum_morpho_clearstarHighYieldUSDC_deposit() public {
        _testDeposit("USDC", "clearstarHighYieldUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_morpho_clearstarHighYieldUSDC_depositWithdraw() public {
        _testDepositWithdraw("USDC", "clearstarHighYieldUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_morpho_kpkUSDCYield_deposit() public {
        _testDeposit("USDC", "kpkUSDCYield", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_morpho_yearnDegenUSDC_deposit() public {
        _testDeposit("USDC", "yearnDegenUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_morpho_hyperithmUSDC_deposit() public {
        _testDeposit("USDC", "hyperithmUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_morpho_clearstarUSDCReactor_deposit() public {
        _testDeposit("USDC", "clearstarUSDCReactor", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_morpho_gauntletUSDCCore_deposit() public {
        _testDeposit("USDC", "gauntletUSDCCore", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_morpho_steakhousePrimeUSDC_deposit() public {
        _testDeposit("USDC", "steakhousePrimeUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_morpho_steakhouseHighYieldUSDC_deposit() public {
        _testDeposit("USDC", "steakhouseHighYieldUSDC", DEPOSIT_AMOUNT);
    }

    // ============ Helper Functions ============

    function _testDeposit(string memory tokenSymbol, string memory vaultName, uint256 amount) internal {
        address token = getToken(tokenSymbol);
        address vault = getMorphoVault(vaultName);
        if (token == address(0) || vault == address(0)) return;

        // Verify vault asset matches
        if (IERC4626(vault).asset() != token) return;

        bytes32 marketId = _computeVaultMarketId(vault);

        if (!adapter.hasMarket(marketId)) {
            adapter.registerVault(Currency.wrap(token), vault);
        }

        _dealTokens(token, user, amount);
        _approveTokens(token, user, address(adapter), amount);

        vm.prank(user);
        adapter.deposit(marketId, amount, recipient);

        assertGt(IERC4626(vault).balanceOf(recipient), 0, "Should receive vault shares");
    }

    function _testDepositWithdraw(string memory tokenSymbol, string memory vaultName, uint256 amount) internal {
        address token = getToken(tokenSymbol);
        address vault = getMorphoVault(vaultName);
        if (token == address(0) || vault == address(0)) return;

        if (IERC4626(vault).asset() != token) return;

        bytes32 marketId = _computeVaultMarketId(vault);

        if (!adapter.hasMarket(marketId)) {
            adapter.registerVault(Currency.wrap(token), vault);
        }

        if (!adapter.authorizedCallers(address(this))) {
            adapter.addAuthorizedCaller(address(this));
        }

        _dealTokens(token, user, amount);
        _approveTokens(token, user, address(adapter), amount);

        vm.prank(user);
        adapter.deposit(marketId, amount, user);

        uint256 shareBalance = IERC4626(vault).balanceOf(user);

        vm.prank(user);
        IERC20(vault).transfer(address(adapter), shareBalance);

        uint256 withdrawn = adapter.withdraw(marketId, shareBalance, recipient);

        assertGt(withdrawn, 0, "Should withdraw tokens");
        assertGe(_getBalance(token, recipient), withdrawn * 99 / 100, "Recipient should receive tokens");
    }
}
