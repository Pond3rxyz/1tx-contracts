// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "../../src/interfaces/IERC4626.sol";

/// @title MockERC4626Vault
/// @notice Mock ERC-4626 vault for testing (Morpho/Fluid)
contract MockERC4626Vault is ERC20, IERC4626 {
    address public immutable _asset;
    uint256 private _totalAssets;

    constructor(address asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _asset = asset_;
    }

    function asset() external view override returns (address) {
        return _asset;
    }

    function totalAssets() external view override returns (uint256) {
        return _totalAssets;
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply) / _totalAssets;
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * _totalAssets) / supply;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        shares = convertToShares(assets);
        if (totalSupply() == 0) shares = assets; // First deposit is 1:1

        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        _totalAssets += assets;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) external view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? shares : (shares * _totalAssets + supply - 1) / supply;
    }

    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        uint256 supply = totalSupply();
        assets = supply == 0 ? shares : (shares * _totalAssets + supply - 1) / supply;

        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        _totalAssets += assets;
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function maxWithdraw(address owner) external view override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? assets : (assets * supply + _totalAssets - 1) / _totalAssets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        uint256 supply = totalSupply();
        shares = supply == 0 ? assets : (assets * supply + _totalAssets - 1) / _totalAssets;

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        _burn(owner, shares);
        _totalAssets -= assets;
        IERC20(_asset).transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return convertToAssets(shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        assets = convertToAssets(shares);

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        _burn(owner, shares);
        _totalAssets -= assets;
        IERC20(_asset).transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function balanceOf(address account) public view override(ERC20, IERC20) returns (uint256) {
        return super.balanceOf(account);
    }

    function totalSupply() public view override(ERC20, IERC20) returns (uint256) {
        return super.totalSupply();
    }

    function transfer(address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        return super.transfer(to, amount);
    }

    function allowance(address owner, address spender) public view override(ERC20, IERC20) returns (uint256) {
        return super.allowance(owner, spender);
    }

    function approve(address spender, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        return super.approve(spender, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        return super.transferFrom(from, to, amount);
    }

    /// @notice Simulate yield accrual by adding assets without minting shares
    function simulateYield(uint256 yieldAmount) external {
        IERC20(_asset).transferFrom(msg.sender, address(this), yieldAmount);
        _totalAssets += yieldAmount;
    }
}
