// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @title MorphoAdapterForkTest
/// @notice Fork tests for MorphoAdapter against Base mainnet
contract MorphoAdapterForkTest is AdapterForkTestBase {
    MorphoAdapter public adapter;

    function setUp() public override {
        super.setUp();

        address deployedAdapter = getDeployedAdapter("morpho");
        if (deployedAdapter != address(0)) {
            adapter = MorphoAdapter(deployedAdapter);
        } else {
            adapter = new MorphoAdapter(address(this));
        }
    }

    // ============ Vault Tests ============

    function test_fork_morpho_steakhouseUSDC_deposit() public {
        _testDeposit("USDC", "steakhouseUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_morpho_steakhouseUSDC_depositWithdraw() public {
        _testDepositWithdraw("USDC", "steakhouseUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_morpho_sparkUSDC_deposit() public {
        _testDeposit("USDC", "sparkUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_morpho_gauntletUSDCPrime_deposit() public {
        _testDeposit("USDC", "gauntletUSDCPrime", DEPOSIT_AMOUNT);
    }

    function test_fork_morpho_steakhousePrimeUSDC_deposit() public {
        _testDeposit("USDC", "steakhousePrimeUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_morpho_re7EUSD_deposit() public {
        _testDeposit("eUSD", "re7EUSD", DEPOSIT_AMOUNT_18);
    }

    function test_fork_morpho_moonwellFrontierCbBTC_deposit() public {
        _testDeposit("cbBTC", "moonwellFrontierCbBTC", 0.01e8);
    }

    function test_fork_morpho_clearstarUSDC_deposit() public {
        _testDeposit("USDC", "clearstarUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_morpho_mevFrontierUSDC_deposit() public {
        _testDeposit("USDC", "mevFrontierUSDC", DEPOSIT_AMOUNT);
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
            vm.prank(adapter.owner());
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
            vm.prank(adapter.owner());
            adapter.registerVault(Currency.wrap(token), vault);
        }

        if (!adapter.authorizedCallers(address(this))) {
            vm.prank(adapter.owner());
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
