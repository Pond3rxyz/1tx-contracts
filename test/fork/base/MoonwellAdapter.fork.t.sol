// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {MoonwellAdapter} from "../../../src/adapters/MoonwellAdapter.sol";

/// @title MoonwellAdapterForkTest
/// @notice Fork tests for MoonwellAdapter against Base mainnet
contract MoonwellAdapterForkTest is AdapterForkTestBase {
    MoonwellAdapter public adapter;

    function setUp() public override {
        super.setUp();

        address deployedAdapter = getDeployedAdapter("moonwell");
        address comptroller = getMoonwellComptroller();

        if (deployedAdapter != address(0)) {
            adapter = MoonwellAdapter(deployedAdapter);
        } else if (comptroller != address(0)) {
            adapter = new MoonwellAdapter(comptroller, address(this));
        }
    }

    // ============ Market Tests ============

    function test_fork_moonwell_usdc_deposit() public {
        _testDeposit("USDC", "usdcMarket", DEPOSIT_AMOUNT);
    }

    function test_fork_moonwell_usdc_depositWithdraw() public {
        _testDepositWithdraw("USDC", "usdcMarket", DEPOSIT_AMOUNT);
    }

    function test_fork_moonwell_dai_deposit() public {
        _testDeposit("DAI", "daiMarket", DEPOSIT_AMOUNT_18);
    }

    function test_fork_moonwell_usdbc_deposit() public {
        _testDeposit("USDbC", "usdbcMarket", DEPOSIT_AMOUNT);
    }

    function test_fork_moonwell_usds_deposit() public {
        _testDeposit("USDS", "usdsMarket", DEPOSIT_AMOUNT_18);
    }

    // ============ Helper Functions ============

    function _testDeposit(string memory tokenSymbol, string memory marketName, uint256 amount) internal {
        if (address(adapter) == address(0)) return;

        address token = getToken(tokenSymbol);
        address mToken = getMoonwellMarket(marketName);
        if (token == address(0) || mToken == address(0)) return;

        bytes32 marketId = _computeMarketId(token);

        if (!adapter.hasMarket(marketId)) {
            vm.prank(adapter.owner());
            adapter.registerMarket(Currency.wrap(token), mToken);
        }

        _dealTokens(token, user, amount);
        _approveTokens(token, user, address(adapter), amount);

        vm.prank(user);
        adapter.deposit(marketId, amount, recipient);

        assertGt(IERC20(mToken).balanceOf(recipient), 0, "Should receive mTokens");
    }

    function _testDepositWithdraw(string memory tokenSymbol, string memory marketName, uint256 amount) internal {
        if (address(adapter) == address(0)) return;

        address token = getToken(tokenSymbol);
        address mToken = getMoonwellMarket(marketName);
        if (token == address(0) || mToken == address(0)) return;

        bytes32 marketId = _computeMarketId(token);

        if (!adapter.hasMarket(marketId)) {
            vm.prank(adapter.owner());
            adapter.registerMarket(Currency.wrap(token), mToken);
        }

        if (!adapter.authorizedCallers(address(this))) {
            vm.prank(adapter.owner());
            adapter.addAuthorizedCaller(address(this));
        }

        _dealTokens(token, user, amount);
        _approveTokens(token, user, address(adapter), amount);

        vm.prank(user);
        adapter.deposit(marketId, amount, user);

        uint256 mTokenBalance = IERC20(mToken).balanceOf(user);

        vm.prank(user);
        IERC20(mToken).transfer(address(adapter), mTokenBalance);

        uint256 withdrawn = adapter.withdraw(marketId, mTokenBalance, recipient);

        assertGt(withdrawn, 0, "Should withdraw tokens");
        assertGe(_getBalance(token, recipient), withdrawn * 99 / 100, "Recipient should receive tokens");
    }
}
