// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICompoundV3} from "../../src/interfaces/ICompoundV3.sol";

/// @title MockCompoundComet
/// @notice Mock Compound V3 Comet for testing
/// @dev Comet tokens are ERC20 and represent supply positions
contract MockCompoundComet is ERC20, ICompoundV3 {
    address public immutable baseToken;
    mapping(address account => mapping(address manager => bool)) public isAllowed;

    constructor(address _baseToken) ERC20("Compound USDC", "cUSDCv3") {
        baseToken = _baseToken;
    }

    function supply(address asset, uint256 amount) external override {
        supplyTo(msg.sender, asset, amount);
    }

    function supplyTo(address to, address asset, uint256 amount) public override {
        require(asset == baseToken, "Invalid asset");
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        _mint(to, amount);
    }

    function withdraw(address asset, uint256 amount) external override {
        require(asset == baseToken, "Invalid asset");
        uint256 balance = balanceOf(msg.sender);
        uint256 toWithdraw = amount > balance ? balance : amount;
        _burn(msg.sender, toWithdraw);
        IERC20(asset).transfer(msg.sender, toWithdraw);
    }

    function withdrawFrom(address from, address to, address asset, uint256 amount) external override {
        require(asset == baseToken, "Invalid asset");
        require(isAllowed[from][msg.sender] || msg.sender == from, "Not allowed");
        _burn(from, amount);
        IERC20(asset).transfer(to, amount);
    }

    function allow(address manager, bool _isAllowed) external override {
        isAllowed[msg.sender][manager] = _isAllowed;
    }

    function balanceOf(address account) public view override(ERC20, ICompoundV3) returns (uint256) {
        return super.balanceOf(account);
    }
}
