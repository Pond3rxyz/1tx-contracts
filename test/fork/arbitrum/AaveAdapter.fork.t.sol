// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {AaveAdapter} from "../../../src/adapters/AaveAdapter.sol";
import {IAavePool} from "../../../src/interfaces/IAavePool.sol";

/// @title AaveAdapterArbitrumForkTest
/// @notice Fork tests for AaveAdapter against Arbitrum mainnet
contract AaveAdapterArbitrumForkTest is AdapterForkTestBase {
    AaveAdapter public adapter;
    IAavePool public aavePool;

    function setUp() public override {
        // Override network to Arbitrum
        networkName = "arbitrumMainnet";
        super.setUp();

        address pool = getAavePool();
        adapter = new AaveAdapter(pool, address(this));
        aavePool = IAavePool(pool);
    }

    // ============ Market Tests ============

    function test_fork_arbitrum_aave_usdc_deposit() public {
        _testDeposit("USDC", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_aave_usdc_depositWithdraw() public {
        _testDepositWithdraw("USDC", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_aave_usdt_deposit() public {
        _testDeposit("USDT", DEPOSIT_AMOUNT);
    }

    function test_fork_arbitrum_aave_dai_deposit() public {
        _testDeposit("DAI", DEPOSIT_AMOUNT_18);
    }

    function test_fork_arbitrum_aave_weth_deposit() public {
        _testDeposit("WETH", 1 ether);
    }

    function test_fork_arbitrum_aave_gho_deposit() public {
        _testDeposit("GHO", DEPOSIT_AMOUNT_18);
    }

    // ============ Helper Functions ============

    function _testDeposit(string memory symbol, uint256 amount) internal {
        address token = getToken(symbol);
        if (token == address(0)) return;

        IAavePool.ReserveData memory reserveData = aavePool.getReserveData(token);
        if (reserveData.aTokenAddress == address(0)) return;

        bytes32 marketId = _computeMarketId(token);

        if (!adapter.hasMarket(marketId)) {
            adapter.registerMarket(Currency.wrap(token));
        }

        _dealTokens(token, user, amount);
        _approveTokens(token, user, address(adapter), amount);

        vm.prank(user);
        adapter.deposit(marketId, amount, recipient);

        address aToken = adapter.getYieldToken(marketId);
        assertGt(_getBalance(aToken, recipient), 0, "Should receive aTokens");
    }

    function _testDepositWithdraw(string memory symbol, uint256 amount) internal {
        address token = getToken(symbol);
        if (token == address(0)) return;

        IAavePool.ReserveData memory reserveData = aavePool.getReserveData(token);
        if (reserveData.aTokenAddress == address(0)) return;

        bytes32 marketId = _computeMarketId(token);

        if (!adapter.hasMarket(marketId)) {
            adapter.registerMarket(Currency.wrap(token));
        }

        if (!adapter.authorizedCallers(address(this))) {
            adapter.addAuthorizedCaller(address(this));
        }

        _dealTokens(token, user, amount);
        _approveTokens(token, user, address(adapter), amount);

        vm.prank(user);
        adapter.deposit(marketId, amount, user);

        address aToken = adapter.getYieldToken(marketId);
        uint256 aTokenBalance = _getBalance(aToken, user);

        vm.prank(user);
        IERC20(aToken).transfer(address(adapter), aTokenBalance);

        uint256 withdrawn = adapter.withdraw(marketId, aTokenBalance, recipient);

        assertGt(withdrawn, 0, "Should withdraw tokens");
        assertGe(_getBalance(token, recipient), withdrawn - 1, "Recipient should receive tokens");
    }
}
