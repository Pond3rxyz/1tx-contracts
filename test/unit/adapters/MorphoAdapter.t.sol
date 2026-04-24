// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AdapterTestBase} from "../../utils/AdapterTestBase.sol";
import {AdapterBase} from "../../../src/adapters/base/AdapterBase.sol";
import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";

contract MorphoAdapterTest is AdapterTestBase {
    MorphoAdapter public adapter;
    MockERC4626Vault public mockVault;

    bytes32 public vaultMarketId;

    function setUp() public override {
        super.setUp();

        adapter = new MorphoAdapter(owner);
        mockVault = new MockERC4626Vault(address(usdc), "Morpho USDC Vault", "mvUSDC");
        vaultMarketId = _computeVaultMarketId(address(mockVault));
    }

    function test_constructor_setsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    function test_getAdapterMetadata_returnsMorphoName() public view {
        MorphoAdapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();

        assertEq(metadata.name, "Morpho Vaults V2");
    }

    function test_registerVault_registersMarket() public {
        vm.prank(owner);
        adapter.registerVault(usdcCurrency, address(mockVault));

        assertTrue(adapter.hasMarket(vaultMarketId));
        assertEq(adapter.getYieldToken(vaultMarketId), address(mockVault));
    }

    function test_registerVault_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.registerVault(usdcCurrency, address(mockVault));
    }

    function test_registerVault_revertsOnInvalidVault() public {
        vm.prank(owner);
        vm.expectRevert(ERC4626Adapter.InvalidVaultAddress.selector);
        adapter.registerVault(usdcCurrency, address(0));
    }

    function test_registerVault_revertsOnAssetMismatch() public {
        MockERC4626Vault usdtVault = new MockERC4626Vault(address(usdt), "Morpho USDT Vault", "mvUSDT");

        vm.prank(owner);
        vm.expectRevert(AdapterBase.AssetMismatch.selector);
        adapter.registerVault(usdcCurrency, address(usdtVault));
    }
}
