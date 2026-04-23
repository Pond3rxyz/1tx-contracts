// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {AdapterTestBase} from "../../utils/AdapterTestBase.sol";
import {AdapterBase} from "../../../src/adapters/base/AdapterBase.sol";
import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {FluidAdapter} from "../../../src/adapters/FluidAdapter.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";

contract FluidAdapterTest is AdapterTestBase {
    FluidAdapter public adapter;
    MockERC4626Vault public mockFToken;

    bytes32 public fTokenMarketId;

    function setUp() public override {
        super.setUp();

        adapter = new FluidAdapter(owner);
        mockFToken = new MockERC4626Vault(address(usdc), "Fluid USDC", "fUSDC");
        fTokenMarketId = _computeVaultMarketId(address(mockFToken));
    }

    function test_constructor_setsOwner() public view {
        assertEq(adapter.owner(), owner);
    }

    function test_getAdapterMetadata_returnsFluidName() public view {
        FluidAdapter.AdapterMetadata memory metadata = adapter.getAdapterMetadata();

        assertEq(metadata.name, "Fluid Lending");
        assertEq(metadata.chainId, block.chainid);
    }

    function test_registerFToken_registersMarket() public {
        vm.prank(owner);
        adapter.registerFToken(usdcCurrency, address(mockFToken));

        assertTrue(adapter.hasMarket(fTokenMarketId));
        assertEq(adapter.getYieldToken(fTokenMarketId), address(mockFToken));
    }

    function test_registerFToken_revertsOnNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.registerFToken(usdcCurrency, address(mockFToken));
    }

    function test_registerFToken_revertsOnInvalidFToken() public {
        vm.prank(owner);
        vm.expectRevert(ERC4626Adapter.InvalidVaultAddress.selector);
        adapter.registerFToken(usdcCurrency, address(0));
    }

    function test_registerFToken_revertsOnAssetMismatch() public {
        MockERC4626Vault usdtFToken = new MockERC4626Vault(address(usdt), "Fluid USDT", "fUSDT");

        vm.prank(owner);
        vm.expectRevert(AdapterBase.AssetMismatch.selector);
        adapter.registerFToken(usdcCurrency, address(usdtFToken));
    }

    function test_requiresAllow_returnsFalse() public view {
        assertFalse(adapter.requiresAllow());
    }
}
