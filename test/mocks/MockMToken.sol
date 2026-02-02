// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMToken} from "../../src/interfaces/IMToken.sol";

/// @title MockMToken
/// @notice Mock Moonwell mToken for testing (Compound V2 style)
contract MockMToken is ERC20, IMToken {
    address public immutable _underlying;
    uint256 private _exchangeRate;
    bool public failMint;
    bool public failRedeem;
    uint256 public mintErrorCode;
    uint256 public redeemErrorCode;

    constructor(address underlying_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _underlying = underlying_;
        // Initial exchange rate: 1 mToken = 1 underlying (scaled by 1e18)
        _exchangeRate = 1e18;
    }

    function underlying() external view override returns (address) {
        return _underlying;
    }

    function setExchangeRate(uint256 rate) external {
        _exchangeRate = rate;
    }

    function setMintFail(bool fail, uint256 errorCode) external {
        failMint = fail;
        mintErrorCode = errorCode;
    }

    function setRedeemFail(bool fail, uint256 errorCode) external {
        failRedeem = fail;
        redeemErrorCode = errorCode;
    }

    function mint(uint256 mintAmount) external override returns (uint256) {
        if (failMint) return mintErrorCode;

        IERC20(_underlying).transferFrom(msg.sender, address(this), mintAmount);

        // Calculate mTokens to mint based on exchange rate
        uint256 mTokenAmount = (mintAmount * 1e18) / _exchangeRate;
        _mint(msg.sender, mTokenAmount);

        return 0; // Success
    }

    function redeem(uint256 redeemTokens) external override returns (uint256) {
        if (failRedeem) return redeemErrorCode;

        _burn(msg.sender, redeemTokens);

        // Calculate underlying to return based on exchange rate
        uint256 underlyingAmount = (redeemTokens * _exchangeRate) / 1e18;
        IERC20(_underlying).transfer(msg.sender, underlyingAmount);

        return 0; // Success
    }

    function redeemUnderlying(uint256 redeemAmount) external override returns (uint256) {
        if (failRedeem) return redeemErrorCode;

        // Calculate mTokens to burn based on exchange rate
        uint256 mTokenAmount = (redeemAmount * 1e18) / _exchangeRate;
        _burn(msg.sender, mTokenAmount);

        IERC20(_underlying).transfer(msg.sender, redeemAmount);

        return 0; // Success
    }

    function exchangeRateCurrent() external view override returns (uint256) {
        return _exchangeRate;
    }

    function exchangeRateStored() external view override returns (uint256) {
        return _exchangeRate;
    }

    function balanceOfUnderlying(address owner) external view override returns (uint256) {
        return (balanceOf(owner) * _exchangeRate) / 1e18;
    }

    function balanceOf(address owner) public view override(ERC20, IMToken) returns (uint256) {
        return super.balanceOf(owner);
    }

    function symbol() public view override(ERC20, IMToken) returns (string memory) {
        return super.symbol();
    }

    function decimals() public view override(ERC20, IMToken) returns (uint8) {
        return super.decimals();
    }
}
