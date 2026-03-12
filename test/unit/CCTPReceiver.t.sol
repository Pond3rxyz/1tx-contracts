// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CCTPReceiver} from "../../src/CCTPReceiver.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MockMessageTransmitter {
    MockERC20 public immutable token;
    bool public shouldSucceed;

    constructor(MockERC20 _token) {
        token = _token;
        shouldSucceed = true;
    }

    function setShouldSucceed(bool _shouldSucceed) external {
        shouldSucceed = _shouldSucceed;
    }

    function receiveMessage(bytes calldata message, bytes calldata) external returns (bool) {
        if (!shouldSucceed) return false;

        bytes calldata body = message[148:];
        uint256 amount;
        assembly {
            amount := calldataload(add(body.offset, 68))
        }
        token.mint(msg.sender, amount);
        return true;
    }
}

contract MockRouter {
    bool public shouldRevert;
    bytes32 public lastInstrumentId;
    uint256 public lastAmount;
    address public lastRecipient;
    IERC20 public stableToken;

    function setStableToken(address _stableToken) external {
        stableToken = IERC20(_stableToken);
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function buyFor(bytes32 instrumentId, uint256 amount, address recipient) external returns (uint256) {
        if (shouldRevert) revert("MockRouter: buyFor failed");
        lastInstrumentId = instrumentId;
        lastAmount = amount;
        lastRecipient = recipient;
        stableToken.transferFrom(msg.sender, address(this), amount);
        return amount;
    }
}

// Re-entrant attacker that tries to call redeem again
contract ReentrantTransmitter {
    CCTPReceiver public receiver;
    MockERC20 public token;
    bool public attacked;

    constructor(CCTPReceiver _receiver, MockERC20 _token) {
        receiver = _receiver;
        token = _token;
    }

    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool) {
        bytes calldata body = message[148:];
        uint256 amount;
        assembly {
            amount := calldataload(add(body.offset, 68))
        }
        token.mint(msg.sender, amount);

        if (!attacked) {
            attacked = true;
            receiver.redeem(message, attestation);
        }
        return true;
    }
}

contract OverMintingTransmitter {
    MockERC20 public immutable token;

    constructor(MockERC20 _token) {
        token = _token;
    }

    function receiveMessage(bytes calldata message, bytes calldata) external returns (bool) {
        bytes calldata body = message[148:];
        uint256 amount;
        assembly {
            amount := calldataload(add(body.offset, 68))
        }
        // Mint more than the message amount to trigger AmountMismatch
        token.mint(msg.sender, amount + 1);
        return true;
    }
}

contract CCTPReceiverTest is Test {
    CCTPReceiver public receiver;
    MockMessageTransmitter public transmitter;
    MockRouter public mockRouter;
    MockERC20 public usdc;

    address public owner;
    address public user;

    event CrossChainBuyExecuted(
        bytes32 indexed instrumentId, address indexed recipient, uint256 amount, uint256 depositedAmount
    );
    event CrossChainBuyFailed(bytes32 indexed instrumentId, address indexed recipient, uint256 amount, bytes reason);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event MessageTransmitterUpdated(address indexed oldTransmitter, address indexed newTransmitter);
    event StableTokenUpdated(address indexed oldToken, address indexed newToken);

    function setUp() public {
        owner = makeAddr("owner");
        user = makeAddr("user");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        transmitter = new MockMessageTransmitter(usdc);
        mockRouter = new MockRouter();
        mockRouter.setStableToken(address(usdc));

        CCTPReceiver impl = new CCTPReceiver();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                CCTPReceiver.initialize.selector, owner, address(mockRouter), address(usdc), address(transmitter)
            )
        );
        receiver = CCTPReceiver(address(proxy));
    }

    // ============ Helpers ============

    function _buildMessage(uint256 amount, bytes memory hookData) internal view returns (bytes memory) {
        bytes memory body = abi.encodePacked(
            uint32(1), // version
            bytes32(uint256(uint160(address(usdc)))), // burnToken
            bytes32(uint256(uint160(address(receiver)))), // mintRecipient
            bytes32(amount), // amount
            bytes32(uint256(uint160(user))), // messageSender
            bytes32(0), // padding
            bytes32(0),
            bytes32(0),
            hookData
        );
        return abi.encodePacked(new bytes(148), body);
    }

    // ============ Initialize ============

    function test_initialize_cannotReinitialize() public {
        vm.expectRevert();
        receiver.initialize(owner, address(mockRouter), address(usdc), address(transmitter));
    }

    function test_initialize_revertsOnZeroRouter() public {
        CCTPReceiver impl = new CCTPReceiver();
        vm.expectRevert(CCTPReceiver.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                CCTPReceiver.initialize.selector, owner, address(0), address(usdc), address(transmitter)
            )
        );
    }

    function test_initialize_revertsOnZeroStableToken() public {
        CCTPReceiver impl = new CCTPReceiver();
        vm.expectRevert(CCTPReceiver.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                CCTPReceiver.initialize.selector, owner, address(mockRouter), address(0), address(transmitter)
            )
        );
    }

    function test_initialize_revertsOnZeroTransmitter() public {
        CCTPReceiver impl = new CCTPReceiver();
        vm.expectRevert(CCTPReceiver.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                CCTPReceiver.initialize.selector, owner, address(mockRouter), address(usdc), address(0)
            )
        );
    }

    // ============ Admin Setters ============

    function test_setRouter_success() public {
        address newRouter = makeAddr("newRouter");
        vm.expectEmit(true, true, false, true);
        emit RouterUpdated(address(mockRouter), newRouter);

        vm.prank(owner);
        receiver.setRouter(newRouter);

        assertEq(receiver.router(), newRouter);
    }

    function test_setRouter_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(CCTPReceiver.ZeroAddress.selector);
        receiver.setRouter(address(0));
    }

    function test_setRouter_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        receiver.setRouter(makeAddr("newRouter"));
    }

    function test_setMessageTransmitter_success() public {
        address newTransmitter = makeAddr("newTransmitter");
        vm.expectEmit(true, true, false, true);
        emit MessageTransmitterUpdated(address(transmitter), newTransmitter);

        vm.prank(owner);
        receiver.setMessageTransmitter(newTransmitter);

        assertEq(receiver.messageTransmitter(), newTransmitter);
    }

    function test_setMessageTransmitter_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(CCTPReceiver.ZeroAddress.selector);
        receiver.setMessageTransmitter(address(0));
    }

    // ============ Redeem — Success with hookData ============

    function test_redeem_success_executesBuyFor() public {
        uint256 amount = 500e6;
        bytes32 instrumentId = bytes32(uint256(42));
        bytes memory hookData = abi.encode(instrumentId, user);
        bytes memory message = _buildMessage(amount, hookData);

        vm.expectEmit(true, true, false, true);
        emit CrossChainBuyExecuted(instrumentId, user, amount, amount);

        bool ok = receiver.redeem(message, bytes("attestation"));
        assertTrue(ok);

        assertEq(mockRouter.lastInstrumentId(), instrumentId);
        assertEq(mockRouter.lastAmount(), amount);
        assertEq(mockRouter.lastRecipient(), user);
    }

    // ============ Redeem — No hookData ============

    function test_redeem_noHookData_returnsTrue() public {
        uint256 amount = 100e6;
        bytes memory message = _buildMessage(amount, "");

        bool ok = receiver.redeem(message, bytes("attestation"));
        assertTrue(ok);

        // No buyFor call
        assertEq(mockRouter.lastAmount(), 0);
        // USDC stays in receiver
        assertEq(usdc.balanceOf(address(receiver)), amount);
    }

    // ============ Redeem — buyFor Failure Fallback ============

    function test_redeem_buyForFails_sendsFundsToRecipient() public {
        uint256 amount = 200e6;
        bytes32 instrumentId = bytes32(uint256(99));
        bytes memory hookData = abi.encode(instrumentId, user);
        bytes memory message = _buildMessage(amount, hookData);

        mockRouter.setShouldRevert(true);

        vm.expectEmit(true, true, false, false);
        emit CrossChainBuyFailed(instrumentId, user, amount, "");

        bool ok = receiver.redeem(message, bytes("attestation"));
        assertTrue(ok);

        // User receives USDC directly as fallback
        assertEq(usdc.balanceOf(user), amount);
        assertEq(usdc.balanceOf(address(receiver)), 0);
    }

    // ============ Redeem — Revert Cases ============

    function test_redeem_revertsOnInvalidMessageLength() public {
        bytes memory shortMessage = new bytes(100);

        vm.expectRevert(CCTPReceiver.InvalidMessageLength.selector);
        receiver.redeem(shortMessage, bytes("attestation"));
    }

    function test_redeem_revertsOnFailedReceiveMessage() public {
        uint256 amount = 100e6;
        bytes memory message = _buildMessage(amount, "");

        transmitter.setShouldSucceed(false);

        vm.expectRevert(CCTPReceiver.CCTPRedeemFailed.selector);
        receiver.redeem(message, bytes("attestation"));
    }

    function test_redeem_revertsOnAmountMismatch() public {
        uint256 messageAmount = 100e6;
        bytes memory message = _buildMessage(messageAmount, "");

        // Pre-mint extra tokens to receiver so balanceAfter - balanceBefore > messageAmount
        usdc.mint(address(receiver), 1);

        // The mock transmitter mints messageAmount, but receiver already had 1 extra
        // Wait — that doesn't affect the delta. We need a transmitter that over-mints.
        // Use an over-minting transmitter instead.
        OverMintingTransmitter overMinter = new OverMintingTransmitter(usdc);
        vm.prank(owner);
        receiver.setMessageTransmitter(address(overMinter));

        vm.expectRevert(CCTPReceiver.AmountMismatch.selector);
        receiver.redeem(message, bytes("attestation"));
    }

    function test_redeem_revertsOnInvalidRecipient() public {
        uint256 amount = 100e6;
        bytes memory hookData = abi.encode(bytes32(uint256(42)), address(0));
        bytes memory message = _buildMessage(amount, hookData);

        vm.expectRevert(CCTPReceiver.InvalidRecipient.selector);
        receiver.redeem(message, bytes("attestation"));
    }

    // ============ Reentrancy ============

    function test_redeem_revertsOnReentrancy() public {
        ReentrantTransmitter reentrantTransmitter = new ReentrantTransmitter(receiver, usdc);

        vm.prank(owner);
        receiver.setMessageTransmitter(address(reentrantTransmitter));

        uint256 amount = 100e6;
        bytes memory message = _buildMessage(amount, "");

        vm.expectRevert(CCTPReceiver.ReentrancyGuard.selector);
        receiver.redeem(message, bytes("attestation"));
    }

    // ============ Invalid hookData length ============

    function test_redeem_revertsOnInvalidHookDataLength() public {
        uint256 amount = 100e6;
        bytes memory hookData = abi.encode(bytes32(uint256(42))); // 32 bytes, not 64
        bytes memory message = _buildMessage(amount, hookData);

        vm.expectRevert(CCTPReceiver.InvalidHookData.selector);
        receiver.redeem(message, bytes("attestation"));
    }

    // ============ Anyone can call redeem ============

    function test_redeem_callableByAnyone() public {
        uint256 amount = 100e6;
        bytes32 instrumentId = bytes32(uint256(7));
        bytes memory hookData = abi.encode(instrumentId, user);
        bytes memory message = _buildMessage(amount, hookData);

        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        bool ok = receiver.redeem(message, bytes("attestation"));
        assertTrue(ok);
        assertEq(mockRouter.lastRecipient(), user);
    }

    // ============ setStableToken ============

    function test_setStableToken_success() public {
        address newToken = makeAddr("newToken");
        vm.expectEmit(true, true, false, true);
        emit StableTokenUpdated(address(usdc), newToken);

        vm.prank(owner);
        receiver.setStableToken(newToken);

        assertEq(receiver.stableToken(), newToken);
    }

    function test_setStableToken_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(CCTPReceiver.ZeroAddress.selector);
        receiver.setStableToken(address(0));
    }

    function test_setStableToken_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        receiver.setStableToken(makeAddr("newToken"));
    }

    // ============ rescueTokens ============

    function test_rescueTokens_success() public {
        uint256 amount = 100e6;
        usdc.mint(address(receiver), amount);

        vm.prank(owner);
        receiver.rescueTokens(IERC20(address(usdc)), owner, amount);

        assertEq(usdc.balanceOf(owner), amount);
        assertEq(usdc.balanceOf(address(receiver)), 0);
    }

    function test_rescueTokens_revertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(CCTPReceiver.ZeroAddress.selector);
        receiver.rescueTokens(IERC20(address(usdc)), address(0), 100);
    }

    function test_rescueTokens_onlyOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        receiver.rescueTokens(IERC20(address(usdc)), user, 100);
    }
}
