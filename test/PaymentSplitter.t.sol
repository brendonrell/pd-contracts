// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PaymentSplitter} from "../src/PaymentSplitter.sol";

/// @dev Minimal factory mock that satisfies PaymentSplitter's IPDFactory
///      interface. Exposes a settable `platformWallet` so the splitter test
///      can exercise the live-lookup rotation behavior in isolation.
contract MockFactoryWallet {
    address public platformWallet;

    constructor(address initial) {
        platformWallet = initial;
    }

    function setPlatformWallet(address w) external {
        platformWallet = w;
    }
}

contract PaymentSplitterTest is Test {
    PaymentSplitter splitter;
    MockFactoryWallet factoryMock;

    address artist = makeAddr("artist");
    address platform = makeAddr("platform");

    function setUp() public {
        factoryMock = new MockFactoryWallet(platform);
        splitter = new PaymentSplitter(artist, address(factoryMock));
    }

    function test_Constructor_SetsImmutables() public view {
        assertEq(splitter.artist(), artist);
        assertEq(splitter.factory(), address(factoryMock));
    }

    function test_Platform_ReadsFromFactoryLive() public {
        // Initial value follows the factory.
        assertEq(splitter.platform(), platform);

        // Rotate on the factory side; splitter view follows instantly.
        address rotated = makeAddr("rotatedPlatform");
        factoryMock.setPlatformWallet(rotated);
        assertEq(splitter.platform(), rotated);
    }

    function test_Constructor_RevertsOnZeroArtist() public {
        vm.expectRevert(PaymentSplitter.ZeroAddress.selector);
        new PaymentSplitter(address(0), address(factoryMock));
    }

    function test_Constructor_RevertsOnZeroFactory() public {
        vm.expectRevert(PaymentSplitter.ZeroAddress.selector);
        new PaymentSplitter(artist, address(0));
    }

    function test_Receive_SplitsSixtyForty() public {
        // 1 ETH royalty → 0.6 artist, 0.4 platform
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(splitter.artistBalance(), 0.6 ether);
        assertEq(splitter.platformBalance(), 0.4 ether);
    }

    function test_Receive_HandlesMultipleDeposits() public {
        (bool ok1,) = address(splitter).call{value: 1 ether}("");
        (bool ok2,) = address(splitter).call{value: 2 ether}("");
        assertTrue(ok1 && ok2);
        // 3 ETH total → 1.8 artist, 1.2 platform
        assertEq(splitter.artistBalance(), 1.8 ether);
        assertEq(splitter.platformBalance(), 1.2 ether);
    }

    function test_Receive_NoRoundingDust() public {
        // Send an amount that would cause rounding if computed independently
        (bool ok,) = address(splitter).call{value: 7}("");
        assertTrue(ok);
        // artistShare = 7 * 60 / 100 = 4 (integer division)
        // platformShare = 7 - 4 = 3
        // Total = 7 — no lost wei
        assertEq(splitter.artistBalance() + splitter.platformBalance(), 7);
    }

    function test_WithdrawArtist_SendsToArtist() public {
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);

        uint256 balanceBefore = artist.balance;
        splitter.withdrawArtist();
        assertEq(artist.balance, balanceBefore + 0.6 ether);
        assertEq(splitter.artistBalance(), 0);
    }

    function test_WithdrawPlatform_SendsToCurrentPlatformWallet() public {
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);

        uint256 balanceBefore = platform.balance;
        splitter.withdrawPlatform();
        assertEq(platform.balance, balanceBefore + 0.4 ether);
        assertEq(splitter.platformBalance(), 0);
    }

    /// @notice Rotation symmetry: royalties received under the original
    ///         platform wallet but withdrawn after rotation flow to the
    ///         NEW wallet — matching the primary-fee live-lookup pattern.
    function test_WithdrawPlatform_RoutesToRotatedWallet() public {
        // Royalty arrives under the original platform wallet.
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(splitter.platformBalance(), 0.4 ether);

        // Factory rotates the platform wallet.
        address rotated = makeAddr("rotatedPlatform");
        factoryMock.setPlatformWallet(rotated);

        uint256 oldBefore = platform.balance;
        uint256 newBefore = rotated.balance;

        splitter.withdrawPlatform();

        // Old wallet sees nothing; new wallet receives the accumulated share.
        assertEq(platform.balance, oldBefore, "rotated-out wallet must not receive");
        assertEq(rotated.balance - newBefore, 0.4 ether);
        assertEq(splitter.platformBalance(), 0);
    }

    function test_WithdrawArtist_RevertsOnZero() public {
        vm.expectRevert(PaymentSplitter.NothingToWithdraw.selector);
        splitter.withdrawArtist();
    }

    function test_WithdrawPlatform_RevertsOnZero() public {
        vm.expectRevert(PaymentSplitter.NothingToWithdraw.selector);
        splitter.withdrawPlatform();
    }

    function test_WithdrawArtist_CallableByAnyone() public {
        // Funds only flow to immutable artist address — no access control needed
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);

        address random = makeAddr("random");
        vm.prank(random);
        splitter.withdrawArtist();
        assertEq(artist.balance, 0.6 ether);
    }

    function test_WithdrawPlatform_CallableByAnyone() public {
        // Funds only flow to factory's current platform wallet — no access control needed
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);

        address random = makeAddr("random");
        vm.prank(random);
        splitter.withdrawPlatform();
        assertEq(platform.balance, 0.4 ether);
    }
}
