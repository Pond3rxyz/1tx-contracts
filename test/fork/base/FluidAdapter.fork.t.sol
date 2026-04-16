// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {FluidAdapter} from "../../../src/adapters/FluidAdapter.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @title FluidAdapterForkTest
/// @notice Fork tests for FluidAdapter against Base mainnet
contract FluidAdapterForkTest is AdapterForkTestBase {
    FluidAdapter public adapter;

    function setUp() public override {
        super.setUp();

        address deployedAdapter = getDeployedAdapter("fluid");
        if (deployedAdapter != address(0) && deployedAdapter.code.length > 0) {
            adapter = FluidAdapter(deployedAdapter);
        } else {
            adapter = new FluidAdapter(address(this));
        }
    }

    // ============ fToken Tests ============

    function test_fork_fluid_fUSDC_deposit() public {
        _testDeposit("USDC", "fUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_fluid_fUSDC_depositWithdraw() public {
        _testDepositWithdraw("USDC", "fUSDC", DEPOSIT_AMOUNT);
    }

    function test_fork_fluid_fEURC_deposit() public {
        _testDeposit("EURC", "fEURC", DEPOSIT_AMOUNT);
    }

    function test_fork_fluid_fGHO_deposit() public {
        _testDeposit("GHO", "fGHO", DEPOSIT_AMOUNT_18);
    }

    // ============ Helper Functions ============

    function _testDeposit(string memory tokenSymbol, string memory fTokenName, uint256 amount) internal {
        address token = getToken(tokenSymbol);
        address fToken = getFluidFToken(fTokenName);
        if (token == address(0) || fToken == address(0)) return;

        // Verify fToken asset matches
        if (IERC4626(fToken).asset() != token) return;

        bytes32 marketId = _computeVaultMarketId(fToken);

        if (!adapter.hasMarket(marketId)) {
            vm.prank(adapter.owner());
            adapter.registerFToken(Currency.wrap(token), fToken);
        }

        _dealTokens(token, user, amount);
        _approveTokens(token, user, address(adapter), amount);

        vm.prank(user);
        adapter.deposit(marketId, amount, recipient);

        assertGt(IERC4626(fToken).balanceOf(recipient), 0, "Should receive fToken shares");
    }

    function _testDepositWithdraw(string memory tokenSymbol, string memory fTokenName, uint256 amount) internal {
        address token = getToken(tokenSymbol);
        address fToken = getFluidFToken(fTokenName);
        if (token == address(0) || fToken == address(0)) return;

        if (IERC4626(fToken).asset() != token) return;

        bytes32 marketId = _computeVaultMarketId(fToken);

        if (!adapter.hasMarket(marketId)) {
            vm.prank(adapter.owner());
            adapter.registerFToken(Currency.wrap(token), fToken);
        }

        if (!adapter.authorizedCallers(address(this))) {
            vm.prank(adapter.owner());
            adapter.addAuthorizedCaller(address(this));
        }

        _dealTokens(token, user, amount);
        _approveTokens(token, user, address(adapter), amount);

        vm.prank(user);
        adapter.deposit(marketId, amount, user);

        uint256 shareBalance = IERC4626(fToken).balanceOf(user);

        vm.prank(user);
        IERC20(fToken).transfer(address(adapter), shareBalance);

        uint256 withdrawn = adapter.withdraw(marketId, shareBalance, recipient);

        assertGt(withdrawn, 0, "Should withdraw tokens");
        assertGe(_getBalance(token, recipient), withdrawn * 99 / 100, "Recipient should receive tokens");
    }
}
