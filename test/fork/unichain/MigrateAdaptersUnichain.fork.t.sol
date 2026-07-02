// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AdapterForkTestBase} from "../../utils/AdapterForkTestBase.sol";
import {AdapterMigrator} from "../../../script/migration/MigrateAdaptersUnichain.s.sol";
import {InstrumentRegistry} from "../../../src/registries/InstrumentRegistry.sol";
import {InstrumentIdLib} from "../../../src/libraries/InstrumentIdLib.sol";
import {MorphoAdapter} from "../../../src/adapters/MorphoAdapter.sol";
import {EulerAdapter} from "../../../src/adapters/EulerAdapter.sol";
import {IERC4626} from "../../../src/interfaces/IERC4626.sol";

/// @dev Minimal view into the live registry's V1-only helper used by the router/frontend.
interface IRegistryDetails {
    function getInstrumentDetails(bytes32 instrumentId)
        external
        view
        returns (address adapter, bytes32 marketId, address yieldToken, uint8 decimals);
}

/// @title MigrateAdaptersUnichainForkTest
/// @notice Runs the real AdapterMigrator against the LIVE Unichain registry on a fork and proves:
///         (1) the new ABI-compat adapters register under the deployed registry (getAdapterMetadata
///         chainId check), (2) instruments re-point to the new adapters, (3) ownership is returned,
///         and (4) deposit + withdraw work at runtime with the production router as authorized caller.
contract MigrateAdaptersUnichainForkTest is AdapterForkTestBase {
    InstrumentRegistry constant REGISTRY = InstrumentRegistry(0x94CC7106f7741FA2d374Ca7b808645fF43b6d2a3);
    address constant ROUTER = 0xde80Ed3CeBdbf688fE12792BDC5d16f4401cC4f2;

    address internal owner;
    address internal usdc;
    address internal gauntletVault;
    address internal eeVault;
    bytes32 internal gauntletId;
    bytes32 internal eeId;

    function setUp() public override {
        networkName = "unichainMainnet";
        super.setUp();

        owner = REGISTRY.owner();
        usdc = getToken("USDC");
        gauntletVault = getMorphoVault("gauntletUSDCC");
        eeVault = getEulerVault("eeUSDC");
        gauntletId =
            InstrumentIdLib.generateInstrumentId(block.chainid, gauntletVault, _computeVaultMarketId(gauntletVault));
        eeId = InstrumentIdLib.generateInstrumentId(block.chainid, eeVault, _computeVaultMarketId(eeVault));
    }

    function test_fork_unichain_migration_repoints_and_runtime_works() public {
        // --- Preconditions: both instruments are live and point at the OLD adapters ---
        (address oldGauntlet,) = REGISTRY.getInstrumentDirect(gauntletId);
        (address oldEuler,) = REGISTRY.getInstrumentDirect(eeId);
        assertTrue(oldGauntlet != address(0), "gauntlet not registered pre-migration");
        assertTrue(oldEuler != address(0), "euler not registered pre-migration");

        // --- Run the migration exactly as the broadcast script would ---
        vm.startPrank(owner);
        AdapterMigrator migrator =
            new AdapterMigrator(REGISTRY, ROUTER, owner, Currency.wrap(usdc), gauntletVault, eeVault, gauntletId, eeId);
        REGISTRY.transferOwnership(address(migrator));
        migrator.migrate();
        vm.stopPrank();

        MorphoAdapter newMorpho = migrator.newMorphoAdapter();
        EulerAdapter newEuler = migrator.newEulerAdapter();
        assertTrue(address(newMorpho) != oldGauntlet, "morpho adapter should be new");
        assertTrue(address(newEuler) != oldEuler, "euler adapter should be new");

        // --- Ownership returned to the original owner ---
        assertEq(REGISTRY.owner(), owner, "registry ownership not returned");
        assertEq(newMorpho.owner(), owner, "morpho ownership not returned");
        assertEq(newEuler.owner(), owner, "euler ownership not returned");

        // --- Instruments now resolve to the new adapters (same IDs) ---
        (address a1,) = REGISTRY.getInstrumentDirect(gauntletId);
        (address a2,) = REGISTRY.getInstrumentDirect(eeId);
        assertEq(a1, address(newMorpho), "gauntlet not re-pointed");
        assertEq(a2, address(newEuler), "euler not re-pointed");

        // --- Router is authorized to withdraw on the new adapters ---
        assertTrue(newMorpho.authorizedCallers(ROUTER), "router not authorized on morpho");
        assertTrue(newEuler.authorizedCallers(ROUTER), "router not authorized on euler");

        // --- Registry helper used by the router/frontend still resolves ---
        (,, address yieldToken, uint8 decimals) = IRegistryDetails(address(REGISTRY)).getInstrumentDetails(gauntletId);
        assertEq(yieldToken, gauntletVault, "yield token mismatch");
        assertGt(decimals, 0, "decimals should be non-zero");

        // --- Runtime: deposit then withdraw via the new Morpho adapter, ROUTER as authorized caller ---
        bytes32 marketId = _computeVaultMarketId(gauntletVault);

        _dealTokens(usdc, user, DEPOSIT_AMOUNT);
        _approveTokens(usdc, user, address(newMorpho), DEPOSIT_AMOUNT);

        vm.prank(user);
        newMorpho.deposit(marketId, DEPOSIT_AMOUNT, user);

        uint256 shares = IERC4626(gauntletVault).balanceOf(user);
        assertGt(shares, 0, "deposit should mint vault shares");

        vm.prank(user);
        IERC20(gauntletVault).transfer(address(newMorpho), shares);

        vm.prank(ROUTER);
        uint256 withdrawn = newMorpho.withdraw(marketId, shares, recipient);

        assertGt(withdrawn, 0, "withdraw should return assets");
        assertGe(_getBalance(usdc, recipient), withdrawn * 99 / 100, "recipient should receive USDC");
    }
}
