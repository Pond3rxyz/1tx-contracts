// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {Permit2Deployer} from "hookmate/artifacts/Permit2.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";
import {V4PositionManagerDeployer} from "hookmate/artifacts/V4PositionManager.sol";
import {V4RouterDeployer} from "hookmate/artifacts/V4Router.sol";

/// @notice Base test contract for hook testing with real Uniswap V4 infrastructure.
/// @dev Deploys real PoolManager, PositionManager, Permit2, and SwapRouter from hookmate artifacts.
contract BaseHookTest is Test {
    IPermit2 permit2;
    IPoolManager poolManager;
    IPositionManager positionManager;
    IUniswapV4Router04 swapRouter;

    function deployArtifacts() internal {
        // Order matters
        _deployPermit2();
        _deployPoolManager();
        _deployPositionManager();
        _deployRouter();

        vm.label(address(permit2), "Permit2");
        vm.label(address(poolManager), "V4PoolManager");
        vm.label(address(positionManager), "V4PositionManager");
        vm.label(address(swapRouter), "V4SwapRouter");
    }

    function deployToken(string memory name, string memory symbol, uint8 decimals)
        internal
        returns (MockERC20 token)
    {
        token = new MockERC20(name, symbol, decimals);
        token.mint(address(this), 10_000_000 * 10 ** decimals);

        token.approve(address(permit2), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token), address(poolManager), type(uint160).max, type(uint48).max);
    }

    function deployCurrencyPair()
        internal
        returns (Currency currency0, Currency currency1)
    {
        MockERC20 token0 = deployToken("Token0", "TK0", 18);
        MockERC20 token1 = deployToken("Token1", "TK1", 18);

        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
    }

    function _deployPermit2() internal {
        address permit2Address = AddressConstants.getPermit2Address();
        if (permit2Address.code.length == 0) {
            vm.etch(permit2Address, Permit2Deployer.deploy().code);
        }
        permit2 = IPermit2(permit2Address);
    }

    function _deployPoolManager() internal {
        poolManager = IPoolManager(V4PoolManagerDeployer.deploy(address(0x4444)));
    }

    function _deployPositionManager() internal {
        positionManager = IPositionManager(
            V4PositionManagerDeployer.deploy(
                address(poolManager), address(permit2), 300_000, address(0), address(0)
            )
        );
    }

    function _deployRouter() internal {
        swapRouter = IUniswapV4Router04(payable(V4RouterDeployer.deploy(address(poolManager), address(permit2))));
    }
}
