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
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        (uint32 destDomain, bytes32 mintRecipient, uint32 minFinality) =
            bridge.bridge(address(usdc), user, amount, 8453, false, 0, bytes32(0), bytes32(0), "");

        assertEq(destDomain, 6);
        assertEq(mintRecipient, bytes32(uint256(uint160(user))));
        assertEq(minFinality, 2000);

        assertEq(messenger.lastAmount(), amount);
        assertEq(messenger.lastDestinationDomain(), 6);
        assertEq(messenger.lastMintRecipient(), bytes32(uint256(uint160(user))));
        assertEq(messenger.lastBurnToken(), address(usdc));
        assertEq(messenger.lastDestinationCaller(), bytes32(0));
        assertEq(messenger.lastMaxFee(), 0);
        assertEq(messenger.lastMinFinalityThreshold(), 2000);
    }

    // ============ Bridge — Fast Mode ============

    function test_bridge_fastMode_success() public {
        uint256 amount = 100e6;
        uint256 maxFee = 50_000;
        bytes32 destinationCaller = bytes32(uint256(uint160(makeAddr("relayer"))));
        bytes32 mintRecipient = bytes32(uint256(uint160(makeAddr("destinationUser"))));

        usdc.mint(address(bridge), amount);

        vm.prank(router);
        (uint32 destDomain, bytes32 resolvedRecipient, uint32 minFinality) =
            bridge.bridge(address(usdc), user, amount, 8453, true, maxFee, destinationCaller, mintRecipient, "");

        assertEq(destDomain, 6);
        assertEq(resolvedRecipient, mintRecipient);
        assertEq(minFinality, 1000);

        assertEq(messenger.lastAmount(), amount);
        assertEq(messenger.lastDestinationDomain(), 6);
        assertEq(messenger.lastMintRecipient(), mintRecipient);
        assertEq(messenger.lastBurnToken(), address(usdc));
        assertEq(messenger.lastDestinationCaller(), destinationCaller);
        assertEq(messenger.lastMaxFee(), maxFee);
        assertEq(messenger.lastMinFinalityThreshold(), 1000);
    }

    // ============ Bridge — Domain 0 (Ethereum Mainnet) ============

    function test_bridge_domain0_ethereumMainnet_success() public {
        uint32 ethChainId = 1;
        uint32 ethCCTPDomain = 0;

        vm.prank(owner);
        bridge.setDestinationDomain(ethChainId, ethCCTPDomain);

        uint256 amount = 100e6;
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        (uint32 destDomain, bytes32 mintRecipient, uint32 minFinality) =
            bridge.bridge(address(usdc), user, amount, ethChainId, false, 0, bytes32(0), bytes32(0), "");

        assertEq(destDomain, 0);
        assertEq(mintRecipient, bytes32(uint256(uint160(user))));
        assertEq(minFinality, 2000);
        assertEq(messenger.lastDestinationDomain(), 0);
    }

    // ============ Bridge — HookData Forwarding ============

    function test_bridge_forwardsHookData() public {
        uint256 amount = 100e6;
        usdc.mint(address(bridge), amount);

        bytes memory hookData = abi.encode(bytes32(uint256(42)), makeAddr("recipient"));

        vm.prank(router);
        bridge.bridge(address(usdc), user, amount, 8453, false, 0, bytes32(0), bytes32(0), hookData);

        assertEq(messenger.lastHookData(), hookData);
    }

    // ============ Bridge — Revert Cases ============

    function test_bridge_revertsWhenCallerNotAuthorized() public {
        uint256 amount = 1e6;
        usdc.mint(address(bridge), amount);

        vm.prank(user);
        vm.expectRevert(CCTPBridge.UnauthorizedCaller.selector);
        bridge.bridge(address(usdc), user, amount, 8453, false, 0, bytes32(0), bytes32(0), "");
    }

    function test_bridge_revertsWhenDomainNotConfigured() public {
        uint256 amount = 1e6;
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CCTPBridge.DestinationDomainNotConfigured.selector, uint32(42161)));
        bridge.bridge(address(usdc), user, amount, 42161, false, 0, bytes32(0), bytes32(0), "");
    }

    function test_bridge_fastMode_revertsOnZeroFee() public {
        uint256 amount = 1e6;
        usdc.mint(address(bridge), amount);

        vm.prank(router);
        vm.expectRevert(CCTPBridge.FastTransferRequiresFee.selector);
        bridge.bridge(address(usdc), user, amount, 8453, true, 0, bytes32(0), bytes32(0), "");
    }

    function test_bridge_revertsOnZeroAmount() public {
        vm.prank(router);
        vm.expectRevert(CCTPBridge.InvalidAmount.selector);
        bridge.bridge(address(usdc), user, 0, 8453, false, 0, bytes32(0), bytes32(0), "");
    }

    function test_bridge_revertsOnZeroStableToken() public {
        vm.prank(router);
        vm.expectRevert(CCTPBridge.InvalidAddress.selector);
        bridge.bridge(address(0), user, 1e6, 8453, false, 0, bytes32(0), bytes32(0), "");
    }

    function test_bridge_revertsOnZeroSender() public {
        vm.prank(router);
        vm.expectRevert(CCTPBridge.InvalidAddress.selector);
        bridge.bridge(address(usdc), address(0), 1e6, 8453, false, 0, bytes32(0), bytes32(0), "");
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
        freshBridge.bridge(address(usdc), user, 1e6, 8453, false, 0, bytes32(0), bytes32(0), "");
    }
}
