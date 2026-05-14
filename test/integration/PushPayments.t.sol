// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PDFactory} from "../../src/PDFactory.sol";
import {PDProject} from "../../src/PDProject.sol";
import {
    MockChainlinkAggregator,
    MockUniswapV3Pool,
    MockWETH,
    MockUSDC,
    RevertingReceiver,
    AcceptingReceiver
} from "../mocks/Mocks.sol";

/// @dev Asserts the core property of the push pattern: PDProject never holds
///      a balance between transactions, wallet rotation immediately routes
///      future fees to the new destination, and a reverting recipient causes
///      the entire mint to roll back (no funds stuck, no partial state).
contract PushPaymentsTest is Test {
    PDFactory factory;
    PDProject project;

    MockChainlinkAggregator chainlinkMock;

    address admin = makeAddr("admin");
    address platformWallet = makeAddr("platformWallet");
    address storageFeeWallet = makeAddr("storageFeeWallet");
    address storageFeeWriter = makeAddr("storageFeeWriter");
    address artist = makeAddr("artist");
    address minter = makeAddr("minter");

    uint256 constant MINT_PRICE = 0.01 ether;

    function setUp() public {
        vm.warp(1_700_000_000);

        chainlinkMock = new MockChainlinkAggregator(int256(3000e8), block.timestamp);
        address pool = address(new MockUniswapV3Pool(int24(-196250)));
        address weth = address(new MockWETH());
        address usdc = address(new MockUSDC());

        factory = new PDFactory(
            admin,
            platformWallet,
            storageFeeWallet,
            storageFeeWriter,
            address(chainlinkMock),
            pool,
            weth,
            usdc
        );

        vm.prank(admin);
        factory.whitelistArtist(artist);

        bytes[] memory chunks = new bytes[](1);
        chunks[0] = bytes("x");
        vm.prank(artist);
        address proj = factory.createProject("P", "P", 100, MINT_PRICE, chunks, "");
        project = PDProject(proj);

        vm.deal(minter, 100 ether);
    }

    function _required(uint256 q) internal view returns (uint256) {
        return (MINT_PRICE + project.currentStorageFeeWei()) * q;
    }

    // ─── Zero balance invariant ──────────────────────────────────────────

    function test_PDProject_HoldsZeroBalance_BeforeAndAfterMint() public {
        assertEq(address(project).balance, 0);
        vm.prank(minter);
        project.mint{value: _required(5)}(5);
        assertEq(address(project).balance, 0);
    }

    function test_PDProject_HoldsZeroBalance_AcrossManyMints() public {
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(minter);
            project.mint{value: _required(1)}(1);
            assertEq(address(project).balance, 0);
        }
    }

    // ─── Wallet rotation ─────────────────────────────────────────────────

    function test_PlatformWalletRotation_RoutesFutureFees() public {
        // First mint goes to original platformWallet.
        uint256 platformBefore1 = platformWallet.balance;
        vm.prank(minter);
        project.mint{value: _required(1)}(1);
        uint256 platformShare = MINT_PRICE - (MINT_PRICE * 9500) / 10000;
        assertEq(platformWallet.balance - platformBefore1, platformShare);

        // Rotate platform wallet.
        address newPlatform = address(new AcceptingReceiver());
        vm.prank(admin);
        factory.setPlatformWallet(newPlatform);

        // Next mint goes to the new wallet; old wallet sees no further delta.
        uint256 oldBefore = platformWallet.balance;
        uint256 newBefore = newPlatform.balance;
        vm.prank(minter);
        project.mint{value: _required(1)}(1);

        assertEq(platformWallet.balance, oldBefore, "old platform wallet must not receive further fees");
        assertEq(newPlatform.balance - newBefore, platformShare);
    }

    function test_StorageFeeWalletRotation_RoutesFutureFees() public {
        uint256 storageFee = project.currentStorageFeeWei();

        uint256 storageBefore1 = storageFeeWallet.balance;
        vm.prank(minter);
        project.mint{value: _required(1)}(1);
        assertEq(storageFeeWallet.balance - storageBefore1, storageFee);

        address newStorage = address(new AcceptingReceiver());
        vm.prank(admin);
        factory.setStorageFeeWallet(newStorage);

        uint256 oldBefore = storageFeeWallet.balance;
        uint256 newBefore = newStorage.balance;
        vm.prank(minter);
        project.mint{value: _required(1)}(1);

        assertEq(storageFeeWallet.balance, oldBefore, "old storage wallet must not receive further fees");
        assertEq(newStorage.balance - newBefore, storageFee);
    }

    // ─── Bad recipient: atomic revert ────────────────────────────────────

    function test_RevertingPlatformWallet_RollsBackMint() public {
        address bad = address(new RevertingReceiver());
        vm.prank(admin);
        factory.setPlatformWallet(bad);

        uint256 artistBefore = artist.balance;
        uint256 storageBefore = storageFeeWallet.balance;
        uint256 totalMintedBefore = project.totalMinted();
        uint256 minterBefore = minter.balance;

        vm.prank(minter);
        vm.expectRevert(PDProject.TransferFailed.selector);
        project.mint{value: _required(1)}(1);

        // Atomic rollback: no token, no funds moved, project still holds 0.
        assertEq(project.totalMinted(), totalMintedBefore);
        assertEq(artist.balance, artistBefore);
        assertEq(storageFeeWallet.balance, storageBefore);
        assertEq(minter.balance, minterBefore);
        assertEq(address(project).balance, 0);
        assertEq(bad.balance, 0);
    }

    function test_RevertingStorageWallet_RollsBackMint() public {
        address bad = address(new RevertingReceiver());
        vm.prank(admin);
        factory.setStorageFeeWallet(bad);

        uint256 artistBefore = artist.balance;
        uint256 platformBefore = platformWallet.balance;
        uint256 totalMintedBefore = project.totalMinted();
        uint256 minterBefore = minter.balance;

        vm.prank(minter);
        vm.expectRevert(PDProject.TransferFailed.selector);
        project.mint{value: _required(1)}(1);

        assertEq(project.totalMinted(), totalMintedBefore);
        assertEq(artist.balance, artistBefore);
        assertEq(platformWallet.balance, platformBefore);
        assertEq(minter.balance, minterBefore);
        assertEq(address(project).balance, 0);
        assertEq(bad.balance, 0);
    }

    function test_RevertingArtist_RollsBackMint() public {
        // Replace artist with a contract whose receive() reverts.
        // The artist is immutable in PDProject — but the *minter* sending to
        // the artist address would revert if it's a reverting contract.
        // To exercise this, we whitelist a contract artist and have it create
        // a project, then attempt a mint.
        RevertingReceiver badArtist = new RevertingReceiver();
        vm.prank(admin);
        factory.whitelistArtist(address(badArtist));

        bytes[] memory chunks = new bytes[](1);
        chunks[0] = bytes("x");
        vm.prank(address(badArtist));
        address proj2 = factory.createProject("X", "X", 100, MINT_PRICE, chunks, "");
        PDProject p2 = PDProject(proj2);

        uint256 required = (MINT_PRICE + p2.currentStorageFeeWei());

        uint256 platformBefore = platformWallet.balance;
        uint256 storageBefore = storageFeeWallet.balance;

        vm.prank(minter);
        vm.expectRevert(PDProject.TransferFailed.selector);
        p2.mint{value: required}(1);

        assertEq(p2.totalMinted(), 0);
        assertEq(platformWallet.balance, platformBefore);
        assertEq(storageFeeWallet.balance, storageBefore);
        assertEq(address(p2).balance, 0);
        assertEq(address(badArtist).balance, 0);
    }
}
