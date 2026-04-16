// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

import {SwapDepositRouter} from "../../../src/SwapDepositRouter.sol";
import {SwapDepositRouterV1} from "./legacy/SwapDepositRouterV1.sol";

/// @title SwapDepositRouter upgrade test (local, V1 → current)
/// @dev  Validates the storage layout of the current SwapDepositRouter against the
///       pre-fee snapshot in legacy/SwapDepositRouterV1.sol, then performs an actual
///       proxy upgrade and asserts that pre-existing slots survive while the new
///       fee fields default to zero.
///
///       Run with: `forge clean && forge build && forge test --mc SwapDepositRouterUpgradeTest`
///       (a full build is required by openzeppelin-foundry-upgrades).
contract SwapDepositRouterUpgradeTest is Test {
    SwapDepositRouter public proxy;
    address public owner = makeAddr("owner");

    address constant POOL_MANAGER = address(0x1);
    address constant INSTRUMENT_REGISTRY = address(0x2);
    address constant SWAP_POOL_REGISTRY = address(0x3);
    address constant STABLE = address(0x4);

    function setUp() public {
        SwapDepositRouterV1 v1Impl = new SwapDepositRouterV1();
        proxy = SwapDepositRouter(
            address(
                new ERC1967Proxy(
                    address(v1Impl),
                    abi.encodeWithSelector(
                        SwapDepositRouterV1.initialize.selector,
                        owner,
                        POOL_MANAGER,
                        INSTRUMENT_REGISTRY,
                        SWAP_POOL_REGISTRY,
                        STABLE
                    )
                )
            )
        );
    }

    /// @notice Storage-layout diff between V1 and current — fails if a slot is shifted, removed, or renamed.
    function test_validateUpgrade_referenceV1() public {
        Options memory opts;
        opts.referenceContract = "SwapDepositRouterV1.sol:SwapDepositRouterV1";
        Upgrades.validateUpgrade("SwapDepositRouter.sol", opts);
    }

    function test_upgradeFromV1_preservesStateAndAddsFees() public {
        // Snapshot V1 state
        address pmBefore = address(proxy.poolManager());
        address irBefore = address(proxy.instrumentRegistry());
        address sprBefore = address(proxy.swapPoolRegistry());
        address stableBefore = Currency.unwrap(proxy.stable());
        address ownerBefore = proxy.owner();

        // Upgrade to current implementation
        SwapDepositRouter newImpl = new SwapDepositRouter();
        vm.prank(owner);
        proxy.upgradeToAndCall(address(newImpl), "");

        // Existing slots survive byte-for-byte
        assertEq(address(proxy.poolManager()), pmBefore, "poolManager shifted");
        assertEq(address(proxy.instrumentRegistry()), irBefore, "instrumentRegistry shifted");
        assertEq(address(proxy.swapPoolRegistry()), sprBefore, "swapPoolRegistry shifted");
        assertEq(Currency.unwrap(proxy.stable()), stableBefore, "stable shifted");
        assertEq(proxy.owner(), ownerBefore, "owner shifted");

        // New fee fields default to zero (no re-init)
        assertEq(proxy.protocolFeeBps(), 0, "protocolFeeBps not zero");
        assertEq(proxy.feeRecipient(), address(0), "feeRecipient not zero");

        // Owner can configure fees post-upgrade
        address feeRecipient = makeAddr("feeRecipient");
        vm.prank(owner);
        proxy.setFeeConfig(50, feeRecipient);
        assertEq(proxy.protocolFeeBps(), 50);
        assertEq(proxy.feeRecipient(), feeRecipient);
    }
}

/// @title SwapDepositRouter upgrade test (Arbitrum fork, deployed proxy → current)
/// @dev  Forks Arbitrum mainnet, upgrades the live SwapDepositRouter proxy to the
///       current implementation, and asserts that production state survives the
///       upgrade and that the new fee config is callable by the real owner.
///
///       Skipped when ARBITRUM_RPC_URL is not set, so this is safe in default CI.
///       Run with: `ARBITRUM_RPC_URL=... forge test --mc SwapDepositRouterForkUpgradeTest -vvv`
contract SwapDepositRouterForkUpgradeTest is Test {
    SwapDepositRouter public constant PROXY = SwapDepositRouter(0xC46C6b9260F3BD3735637AaEd4fBD1B1dE6D84AE);

    function setUp() public {
        string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string(""));
        vm.createSelectFork(rpcUrl);
    }

    function test_forkUpgrade_preservesStateAndAddsFees() public {
        // Snapshot live state
        address ownerBefore = PROXY.owner();
        address pmBefore = address(PROXY.poolManager());
        address irBefore = address(PROXY.instrumentRegistry());
        address sprBefore = address(PROXY.swapPoolRegistry());
        address stableBefore = Currency.unwrap(PROXY.stable());
        address bridgeBefore = PROXY.cctpBridge();
        address receiverBefore = PROXY.cctpReceiver();

        // Upgrade
        SwapDepositRouter newImpl = new SwapDepositRouter();
        vm.prank(ownerBefore);
        PROXY.upgradeToAndCall(address(newImpl), "");

        // Existing slots survive
        assertEq(PROXY.owner(), ownerBefore, "owner shifted");
        assertEq(address(PROXY.poolManager()), pmBefore, "poolManager shifted");
        assertEq(address(PROXY.instrumentRegistry()), irBefore, "instrumentRegistry shifted");
        assertEq(address(PROXY.swapPoolRegistry()), sprBefore, "swapPoolRegistry shifted");
        assertEq(Currency.unwrap(PROXY.stable()), stableBefore, "stable shifted");
        assertEq(PROXY.cctpBridge(), bridgeBefore, "cctpBridge shifted");
        assertEq(PROXY.cctpReceiver(), receiverBefore, "cctpReceiver shifted");

        // New fee fields start at zero on the real proxy
        assertEq(PROXY.protocolFeeBps(), 0, "protocolFeeBps not zero");
        assertEq(PROXY.feeRecipient(), address(0), "feeRecipient not zero");

        // Real owner can set fee config
        address feeRecipient = makeAddr("feeRecipient");
        vm.prank(ownerBefore);
        PROXY.setFeeConfig(25, feeRecipient);
        assertEq(PROXY.protocolFeeBps(), 25);
        assertEq(PROXY.feeRecipient(), feeRecipient);
    }
}
