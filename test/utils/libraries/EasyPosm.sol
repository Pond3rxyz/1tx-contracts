// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.21;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @title Easy Position Manager
/// @notice A library for abstracting Position Manager calldata
library EasyPosm {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PositionInfoLibrary for PositionInfo;

    struct MintData {
        uint256 balance0Before;
        uint256 balance1Before;
        bytes[] params;
        bytes actions;
    }

    function mint(
        IPositionManager posm,
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        address recipient,
        uint256 deadline,
        bytes memory hookData
    ) internal returns (uint256 tokenId, BalanceDelta delta) {
        (Currency currency0, Currency currency1) = (poolKey.currency0, poolKey.currency1);

        MintData memory mintData = MintData({
            balance0Before: currency0.balanceOf(address(this)),
            balance1Before: currency1.balanceOf(address(this)),
            actions: new bytes(0),
            params: new bytes[](4)
        });

        mintData.actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );

        mintData.params[0] =
            abi.encode(poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData);
        mintData.params[1] = abi.encode(currency0, currency1);
        mintData.params[2] = abi.encode(currency0, recipient);
        mintData.params[3] = abi.encode(currency1, recipient);

        tokenId = posm.nextTokenId();
        uint256 valueToPass = currency0.isAddressZero() ? amount0Max : 0;
        posm.modifyLiquidities{value: valueToPass}(abi.encode(mintData.actions, mintData.params), deadline);

        delta = toBalanceDelta(
            -(mintData.balance0Before - currency0.balanceOf(address(this))).toInt128(),
            -(mintData.balance1Before - currency1.balanceOf(address(this))).toInt128()
        );
    }

    function decreaseLiquidity(
        IPositionManager posm,
        uint256 tokenId,
        uint256 liquidityToRemove,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline,
        bytes memory hookData
    ) internal returns (BalanceDelta delta) {
        (Currency currency0, Currency currency1) = getCurrencies(posm, tokenId);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidityToRemove, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(currency0, currency1, recipient);

        uint256 balance0Before = currency0.balanceOf(address(this));
        uint256 balance1Before = currency1.balanceOf(address(this));

        posm.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)), params), deadline
        );

        delta = toBalanceDelta(
            (currency0.balanceOf(address(this)) - balance0Before).toInt128(),
            (currency1.balanceOf(address(this)) - balance1Before).toInt128()
        );
    }

    function getCurrencies(IPositionManager posm, uint256 tokenId)
        internal
        view
        returns (Currency currency0, Currency currency1)
    {
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(tokenId);
        return (key.currency0, key.currency1);
    }
}
