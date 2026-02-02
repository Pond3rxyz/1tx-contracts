// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {CompoundAdapter} from "../../../src/adapters/CompoundAdapter.sol";
import {ICompoundV3} from "../../../src/interfaces/ICompoundV3.sol";

/// @title CompoundAdapterForkTest
/// @notice Fork tests for CompoundAdapter against Base mainnet
contract CompoundAdapterForkTest is AdapterForkTestBase {
    CompoundAdapter public adapter;

    function setUp() public override {
        super.setUp();

        address deployedAdapter = getDeployedAdapter("compound");
        if (deployedAdapter != address(0)) {
            adapter = CompoundAdapter(deployedAdapter);
        } else {
            adapter = new CompoundAdapter(address(this));
        }
    }

    // ============ Market Tests ============

    function test_fork_compound_usdcComet_deposit() public {
        _testDeposit("USDC", "usdcComet", DEPOSIT_AMOUNT);
    }

    function test_fork_compound_usdcComet_depositWithdraw() public {
        _testDepositWithdraw("USDC", "usdcComet", DEPOSIT_AMOUNT);
    }

    function test_fork_compound_usdbcComet_deposit() public {
        _testDeposit("USDbC", "usdbcComet", DEPOSIT_AMOUNT);
    }

    function test_fork_compound_usdsComet_deposit() public {
        _testDeposit("USDS", "usdsComet", DEPOSIT_AMOUNT_18);
    }

    // ============ Helper Functions ============

    function _testDeposit(string memory tokenSymbol, string memory cometName, uint256 amount) internal {
        address token = getToken(tokenSymbol);
        address comet = getCompoundComet(cometName);
        if (token == address(0) || comet == address(0)) return;

        bytes32 marketId = _computeMarketId(token);

        if (!adapter.hasMarket(marketId)) {
            vm.prank(adapter.owner());
            adapter.registerMarket(Currency.wrap(token), comet);
        }

        _dealTokens(token, user, amount);
        _approveTokens(token, user, address(adapter), amount);

        vm.prank(user);
        adapter.deposit(marketId, amount, recipient);

        assertGt(ICompoundV3(comet).balanceOf(recipient), 0, "Should receive Comet tokens");
    }

    function _testDepositWithdraw(string memory tokenSymbol, string memory cometName, uint256 amount) internal {
        address token = getToken(tokenSymbol);
        address comet = getCompoundComet(cometName);
        if (token == address(0) || comet == address(0)) return;

        bytes32 marketId = _computeMarketId(token);

        if (!adapter.hasMarket(marketId)) {
            vm.prank(adapter.owner());
            adapter.registerMarket(Currency.wrap(token), comet);
        }

        if (!adapter.authorizedCallers(address(this))) {
            vm.prank(adapter.owner());
            adapter.addAuthorizedCaller(address(this));
        }

        _dealTokens(token, user, amount);
        _approveTokens(token, user, address(adapter), amount);

        vm.prank(user);
        adapter.deposit(marketId, amount, user);

        uint256 cometBalance = ICompoundV3(comet).balanceOf(user);

        vm.prank(user);
        IERC20(comet).transfer(address(adapter), cometBalance);

        uint256 withdrawn = adapter.withdraw(marketId, cometBalance, recipient);

        assertGt(withdrawn, 0, "Should withdraw tokens");
        assertGe(_getBalance(token, recipient), withdrawn - 1, "Recipient should receive tokens");
    }
}
