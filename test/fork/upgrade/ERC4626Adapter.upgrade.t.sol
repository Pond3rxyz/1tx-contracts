// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

import {ERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {EulerAdapter} from "../../../src/adapters/EulerAdapter.sol";
import {FluidAdapter} from "../../../src/adapters/FluidAdapter.sol";
import {ERC4626AdapterV1} from "./legacy/ERC4626AdapterV1.sol";
import {MockERC4626Vault} from "../../mocks/MockERC4626Vault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @title ERC4626Adapter upgrade tests (V1 snapshot -> current)
/// @dev Validates storage layout against the V1 snapshot, then upgrades a V1 proxy in place and
///      asserts markets + authorizedCallers survive. Also covers the Morpho/Euler/Fluid subclasses,
///      which add no storage and therefore share this layout.
///      Requires a full build: `forge clean && forge build && forge test --mc ERC4626AdapterUpgradeTest`.
contract ERC4626AdapterUpgradeTest is Test {
    ERC4626AdapterV1 public proxy;
    MockERC4626Vault public vault;
    MockERC20 public usdc;

    address public owner = makeAddr("owner");
    address public caller = makeAddr("router");

    Currency public currency;
    bytes32 public marketId;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new MockERC4626Vault(address(usdc), "Generic USDC Vault", "gUSDC");

        currency = Currency.wrap(address(usdc));
        marketId = bytes32(uint256(uint160(address(vault))));

        ERC4626AdapterV1 impl = new ERC4626AdapterV1();
        proxy = ERC4626AdapterV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(ERC4626AdapterV1.initialize, (owner))))
        );

        vm.startPrank(owner);
        proxy.registerMarket(currency, address(vault));
        proxy.setAuthorizedCaller(caller, true);
        vm.stopPrank();
    }

    /// @notice Base ERC4626Adapter layout must remain compatible with the V1 snapshot.
    function test_validateUpgrade_referenceV1() public {
        Options memory opts;
        opts.referenceContract = "ERC4626AdapterV1.sol:ERC4626AdapterV1";
        Upgrades.validateUpgrade("ERC4626Adapter.sol", opts);
    }

    /// @notice Subclasses add no storage, so they must validate against the same V1 layout.
    /// @dev `missing-initializer` is suppressed: the subclass initializer is inherited from
    ///      ERC4626Adapter (proven at runtime by {test_upgradeFromV1_toMorphoSubclass}), which the
    ///      static validator can't see. The storage-layout diff — the part we care about — still runs.
    function _validateSubclass(string memory contractName) private {
        Options memory opts;
        opts.referenceContract = "ERC4626AdapterV1.sol:ERC4626AdapterV1";
        opts.unsafeAllow = "missing-initializer";
        Upgrades.validateUpgrade(contractName, opts);
    }

    function test_validateUpgrade_subclassMorpho() public {
        _validateSubclass("MorphoAdapter.sol");
    }

    function test_validateUpgrade_subclassEuler() public {
        _validateSubclass("EulerAdapter.sol");
    }

    function test_validateUpgrade_subclassFluid() public {
        _validateSubclass("FluidAdapter.sol");
    }

    function test_upgradeFromV1_preservesState() public {
        assertTrue(proxy.hasMarket(marketId), "market missing before upgrade");
        assertTrue(proxy.authorizedCallers(caller), "caller missing before upgrade");

        ERC4626Adapter newImpl = new ERC4626Adapter();
        vm.prank(owner);
        proxy.upgradeToAndCall(address(newImpl), "");

        ERC4626Adapter upgraded = ERC4626Adapter(address(proxy));
        assertTrue(upgraded.hasMarket(marketId), "market lost across upgrade");
        assertEq(upgraded.getYieldToken(marketId), address(vault), "yieldToken shifted");
        assertEq(Currency.unwrap(upgraded.getMarketCurrency(marketId)), address(usdc), "currency shifted");
        assertTrue(upgraded.authorizedCallers(caller), "authorizedCaller lost across upgrade");
        assertEq(upgraded.owner(), owner, "owner shifted");
    }

    /// @notice A V1 base proxy can be upgraded to a concrete subclass (Morpho) intact.
    function test_upgradeFromV1_toMorphoSubclass() public {
        MorphoAdapter newImpl = new MorphoAdapter();
        vm.prank(owner);
        proxy.upgradeToAndCall(address(newImpl), "");

        MorphoAdapter upgraded = MorphoAdapter(address(proxy));
        assertTrue(upgraded.hasMarket(marketId), "market lost across upgrade");
        assertTrue(upgraded.authorizedCallers(caller), "authorizedCaller lost across upgrade");
    }
}
