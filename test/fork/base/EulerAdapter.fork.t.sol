// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {EulerAdapter} from "../../../src/adapters/EulerAdapter.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @title EulerAdapterBaseForkTest
/// @notice Fork tests for EulerAdapter against Base mainnet
contract EulerAdapterBaseForkTest is AdapterForkTestBase {
    EulerAdapter public adapter;

    function setUp() public override {
        // Override network to Base
        networkName = "baseMainnet";
        super.setUp();

        adapter = new EulerAdapter(address(this));
    }

    // ============ Vault Tests ============

    function test_fork_base_EulerEarn_eeUSDC_deposit() public {
        _testDeposit("USDC", "eeUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_base_EulerEarn_eeUSDC_depositWithdraw() public {
        _testDepositWithdraw("USDC", "eeUSDC", DEPOSIT_AMOUNT);
    }

    // ============ Helper Functions ============

    function _testDeposit(
        string memory tokenSymbol,
        string memory vaultName,
        uint256 amount
    ) internal {
        address token = getToken(tokenSymbol);
        address vault = getEulerVault(vaultName);
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

        assertGt(
            IERC4626(vault).balanceOf(recipient),
            0,
            "Should receive vault shares"
        );
    }

    function _testDepositWithdraw(
        string memory tokenSymbol,
        string memory vaultName,
        uint256 amount
    ) internal {
        address token = getToken(tokenSymbol);
        address vault = getEulerVault(vaultName);
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
        assertGe(
            _getBalance(token, recipient),
            (withdrawn * 99) / 100,
            "Recipient should receive tokens"
        );
    }
}
