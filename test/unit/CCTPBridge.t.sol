// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {CCTPBridge} from "../../src/CCTPBridge.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MockTokenMessengerV2BridgeTest {
    uint256 public lastAmount;
    uint32 public lastDestinationDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32 public lastMinFinalityThreshold;
    bytes public lastHookData;

    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        lastAmount = amount;
        lastDestinationDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastHookData = hookData;
    }
}

contract CCTPBridgeTest is Test {
    CCTPBridge public bridge;
    MockTokenMessengerV2BridgeTest public messenger;
    MockERC20 public usdc;

    address public owner;
    address public router;
    address public user;

    function setUp() public {
        owner = makeAddr("owner");
        router = makeAddr("router");
        user = makeAddr("user");

        CCTPBridge implementation = new CCTPBridge();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeWithSelector(CCTPBridge.initialize.selector, owner));
        bridge = CCTPBridge(address(proxy));
        messenger = new MockTokenMessengerV2BridgeTest();
        usdc = new MockERC20("USD Coin", "USDC", 6);

        vm.prank(owner);
        bridge.setTokenMessenger(address(messenger));

        vm.prank(owner);
        bridge.setDestinationDomain(8453, 6);

        vm.prank(owner);
        bridge.setAuthorizedCaller(router, true);

        vm.prank(owner);
        bridge.setDestinationCaller(8453, bytes32(uint256(uint160(makeAddr("destinationCaller")))));

        vm.prank(owner);
        bridge.setDestinationMintRecipient(8453, bytes32(uint256(uint160(makeAddr("mintRecipient")))));
    }

    // ============ Initialize / Upgrade ============

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        bridge.initialize(owner);
    }

    function test_upgrade_onlyOwner() public {
        CCTPBridge newImpl = new CCTPBridge();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        bridge.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_success() public {
        CCTPBridge newImpl = new CCTPBridge();

        vm.prank(owner);
        bridge.upgradeToAndCall(address(newImpl), "");

        assertEq(bridge.owner(), owner);
        assertEq(bridge.tokenMessenger(), address(messenger));
    }

    // ============ Bridge — Standard Mode ============

    function test_bridge_standardMode_success() public {
        uint256 amount = 100e6;
        bytes32 expectedRecipient = bytes32(uint256(uint160(makeAddr("mintRecipient"))));
        bytes32 expectedCaller = bytes32(uint256(uint160(makeAddr("destinationCaller"))));
        usdc.mint(address(bridge), amount);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit CCTPBridge.BridgeExecuted(user, 6, expectedRecipient, expectedCaller, amount, 0, 2000);

        vm.prank(router);
        (uint32 destDomain, bytes32 resolvedRecipient, uint32 minFinality) =
            bridge.bridge(address(usdc), user, amount, 8453, false, 0, "");

        assertEq(destDomain, 6);
        assertEq(resolvedRecipient, expectedRecipient);
        assertEq(minFinality, 2000);

        assertEq(messenger.lastAmount(), amount);
        assertEq(messenger.lastDestinationDomain(), 6);
        assertEq(messenger.lastMintRecipient(), expectedRecipient);
        assertEq(messenger.lastBurnToken(), address(usdc));
        assertEq(messenger.lastDestinationCaller(), bytes32(uint256(uint160(makeAddr("destinationCaller")))));
        assertEq(messenger.lastMaxFee(), 0);
        assertEq(messenger.lastMinFinalityThreshold(), 2000);
    }

    // ============ Bridge — Fast Mode ============

    function test_bridge_fastMode_success() public {
        uint256 amount = 100e6;
        uint256 maxFee = 50_000;
        bytes32 expectedRecipient = bytes32(uint256(uint160(makeAddr("mintRecipient"))));
        bytes32 expectedCaller = bytes32(uint256(uint160(makeAddr("destinationCaller"))));

        usdc.mint(address(bridge), amount);

        vm.expectEmit(true, true, false, true, address(bridge));
        emit CCTPBridge.BridgeExecuted(user, 6, expectedRecipient, expectedCaller, amount, maxFee, 1000);

        vm.prank(router);
        (uint32 destDomain, bytes32 resolvedRecipient, uint32 minFinality) =
            bridge.bridge(address(usdc), user, amount, 8453, true, maxFee, "");

        assertEq(destDomain, 6);
        assertEq(resolvedRecipient, expectedRecipient);
        assertEq(minFinality, 1000);

        assertEq(messenger.lastAmount(), amount);
        assertEq(messenger.lastDestinationDomain(), 6);
        assertEq(messenger.lastMintRecipient(), expectedRecipient);
        assertEq(messenger.lastBurnToken(), address(usdc));
        assertEq(messenger.lastDestinationCaller(), bytes32(uint256(uint160(makeAddr("destinationCaller")))));
        assertEq(messenger.lastMaxFee(), maxFee);
        assertEq(messenger.lastMinFinalityThreshold(), 1000);
    }

    // ============ Bridge — Domain 0 (Ethereum Mainnet) ============

    function test_bridge_domain0_ethereumMainnet_success() public {
        uint32 ethChainId = 1;
        uint32 ethCCTPDomain = 0;
        bytes32 ethRecipient = bytes32(uint256(uint160(makeAddr("ethRecipient"))));

        vm.startPrank(owner);
        bridge.setDestinationDomain(ethChainId, ethCCTPDomain);
        bridge.setDestinationCaller(ethChainId, bytes32(uint256(uint160(makeAddr("ethCaller")))));
        bridge.setDestinationMintRecipient(ethChainId, ethRecipient);
        vm.stopPrank();

        uint256 amount = 100e6;
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        (uint32 destDomain, bytes32 resolvedRecipient, uint32 minFinality) =
            bridge.bridge(address(usdc), user, amount, ethChainId, false, 0, "");

        assertEq(destDomain, 0);
        assertEq(resolvedRecipient, ethRecipient);
        assertEq(minFinality, 2000);
        assertEq(messenger.lastDestinationDomain(), 0);
    }

    // ============ Bridge — HookData Forwarding ============

    function test_bridge_forwardsHookData() public {
        uint256 amount = 100e6;
        usdc.mint(address(bridge), amount);

        bytes memory hookData = abi.encode(bytes32(uint256(42)), makeAddr("recipient"));

        vm.prank(router);
        bridge.bridge(address(usdc), user, amount, 8453, false, 0, hookData);

        assertEq(messenger.lastHookData(), hookData);
    }

    // ============ Bridge — MintRecipient from Mapping ============

    function test_bridge_usesConfiguredMintRecipient() public {
        bytes32 configuredRecipient = bytes32(uint256(uint160(makeAddr("mintRecipient"))));

        uint256 amount = 100e6;
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        (, bytes32 resolvedRecipient,) = bridge.bridge(address(usdc), user, amount, 8453, false, 0, "");

        assertEq(resolvedRecipient, configuredRecipient);
        assertEq(messenger.lastMintRecipient(), configuredRecipient);
    }

    function test_bridge_revertsWhenMintRecipientNotConfigured() public {
        // Configure domain 42161 and destinationCaller but NOT mintRecipient
        vm.startPrank(owner);
        bridge.setDestinationDomain(42161, 3);
        bridge.setDestinationCaller(42161, bytes32(uint256(uint160(makeAddr("caller")))));
        vm.stopPrank();

        uint256 amount = 100e6;
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CCTPBridge.MintRecipientNotConfigured.selector, uint32(42161)));
        bridge.bridge(address(usdc), user, amount, 42161, false, 0, "");
    }

    // ============ Bridge — DestinationCaller from Mapping ============

    function test_bridge_usesConfiguredDestinationCaller() public {
        bytes32 configuredCaller = bytes32(uint256(uint160(makeAddr("destinationCaller"))));

        uint256 amount = 100e6;
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        bridge.bridge(address(usdc), user, amount, 8453, false, 0, "");

        assertEq(messenger.lastDestinationCaller(), configuredCaller);
    }

    function test_bridge_revertsWhenDestinationCallerNotConfigured() public {
        // Configure domain 42161 and mintRecipient but NOT destinationCaller
        vm.startPrank(owner);
        bridge.setDestinationDomain(42161, 3);
        bridge.setDestinationMintRecipient(42161, bytes32(uint256(uint160(makeAddr("recipient")))));
        vm.stopPrank();

        uint256 amount = 100e6;
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CCTPBridge.DestinationCallerNotConfigured.selector, uint32(42161)));
        bridge.bridge(address(usdc), user, amount, 42161, false, 0, "");
    }

    // ============ Admin — Access Control ============

    function test_setTokenMessenger_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        bridge.setTokenMessenger(makeAddr("newMessenger"));
    }

    function test_setTokenMessenger_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(CCTPBridge.InvalidAddress.selector);
        bridge.setTokenMessenger(address(0));
    }

    function test_setDestinationDomain_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        bridge.setDestinationDomain(1, 0);
    }

    function test_setAuthorizedCaller_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(CCTPBridge.InvalidAddress.selector);
        bridge.setAuthorizedCaller(address(0), true);
    }

    function test_setAuthorizedCaller_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        bridge.setAuthorizedCaller(makeAddr("caller"), true);
    }

    // ============ Admin — Remove Domain ============

    function test_removeDestinationDomain_success() public {
        vm.prank(owner);
        bridge.removeDestinationDomain(8453);

        usdc.mint(address(bridge), 1e6);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CCTPBridge.DestinationDomainNotConfigured.selector, uint32(8453)));
        bridge.bridge(address(usdc), user, 1e6, 8453, false, 0, "");
    }

    function test_removeDestinationDomain_revertsIfNotConfigured() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CCTPBridge.DomainNotConfigured.selector, uint32(42161)));
        bridge.removeDestinationDomain(42161);
    }

    function test_removeDestinationDomain_revertsForNonOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        bridge.removeDestinationDomain(8453);
    }

    // ============ Admin — Rescue Tokens ============

    function test_rescueTokens_success() public {
        uint256 amount = 50e6;
        usdc.mint(address(bridge), amount);

        vm.prank(owner);
        bridge.rescueTokens(address(usdc), owner, amount);

        assertEq(usdc.balanceOf(owner), amount);
        assertEq(usdc.balanceOf(address(bridge)), 0);
    }

    function test_rescueTokens_revertsForNonOwner() public {
        usdc.mint(address(bridge), 1e6);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        bridge.rescueTokens(address(usdc), user, 1e6);
    }

    function test_rescueTokens_revertsOnZeroToken() public {
        vm.prank(owner);
        vm.expectRevert(CCTPBridge.InvalidAddress.selector);
        bridge.rescueTokens(address(0), owner, 1e6);
    }

    function test_rescueTokens_revertsOnZeroTo() public {
        vm.prank(owner);
        vm.expectRevert(CCTPBridge.InvalidAddress.selector);
        bridge.rescueTokens(address(usdc), address(0), 1e6);
    }

    // ============ Bridge — Revert Cases ============

    function test_bridge_revertsWhenCallerNotAuthorized() public {
        uint256 amount = 1e6;
        usdc.mint(address(bridge), amount);

        vm.prank(user);
        vm.expectRevert(CCTPBridge.UnauthorizedCaller.selector);
        bridge.bridge(address(usdc), user, amount, 8453, false, 0, "");
    }

    function test_bridge_revertsWhenDomainNotConfigured() public {
        uint256 amount = 1e6;
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CCTPBridge.DestinationDomainNotConfigured.selector, uint32(42161)));
        bridge.bridge(address(usdc), user, amount, 42161, false, 0, "");
    }

    function test_bridge_fastMode_revertsOnZeroFee() public {
        uint256 amount = 1e6;
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        vm.expectRevert(CCTPBridge.FastTransferRequiresFee.selector);
        bridge.bridge(address(usdc), user, amount, 8453, true, 0, "");
    }

    function test_bridge_revertsOnZeroAmount() public {
        vm.prank(router);
        vm.expectRevert(CCTPBridge.InvalidAmount.selector);
        bridge.bridge(address(usdc), user, 0, 8453, false, 0, "");
    }

    function test_bridge_revertsOnZeroStableToken() public {
        vm.prank(router);
        vm.expectRevert(CCTPBridge.InvalidAddress.selector);
        bridge.bridge(address(0), user, 1e6, 8453, false, 0, "");
    }

    function test_bridge_revertsOnZeroSender() public {
        vm.prank(router);
        vm.expectRevert(CCTPBridge.InvalidAddress.selector);
        bridge.bridge(address(usdc), address(0), 1e6, 8453, false, 0, "");
    }

    function test_bridge_revertsWhenTokenMessengerNotConfigured() public {
        CCTPBridge freshBridge = CCTPBridge(
            address(
                new ERC1967Proxy(
                    address(new CCTPBridge()), abi.encodeWithSelector(CCTPBridge.initialize.selector, owner)
                )
            )
        );

        vm.startPrank(owner);
        freshBridge.setDestinationDomain(8453, 6);
        freshBridge.setAuthorizedCaller(router, true);
        vm.stopPrank();

        usdc.mint(address(freshBridge), 1e6);

        vm.prank(router);
        vm.expectRevert(CCTPBridge.TokenMessengerNotConfigured.selector);
        freshBridge.bridge(address(usdc), user, 1e6, 8453, false, 0, "");
    }
}
