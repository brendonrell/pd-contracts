// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PDFactory} from "../src/PDFactory.sol";
import {PDCollection} from "../src/PDCollection.sol";

contract PDFactoryTest is Test {
    PDFactory factory;

    address admin = makeAddr("admin");
    address platformWallet = makeAddr("platformWallet");
    address artist = makeAddr("artist");
    address artist2 = makeAddr("artist2");
    address random = makeAddr("random");

    string constant BASE_URI = "https://api.pricediscussion.com/token/";

    function setUp() public {
        vm.prank(admin);
        factory = new PDFactory(admin, platformWallet, BASE_URI);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _sampleScript() internal pure returns (bytes[] memory chunks) {
        chunks = new bytes[](1);
        chunks[0] = bytes("function draw(p5) { p5.background(0); }");
    }

    function _createSampleCollection(address _artist) internal returns (address collection) {
        vm.prank(_artist);
        collection = factory.createCollection("Kiki", "KIKI", 2222, 0.011 ether, _sampleScript());
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    function test_Constructor_SetsState() public view {
        assertEq(factory.admin(), admin);
        assertEq(factory.platformWallet(), platformWallet);
        assertEq(factory.baseTokenURI(), BASE_URI);
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        new PDFactory(address(0), platformWallet, BASE_URI);
    }

    function test_Constructor_RevertsOnZeroPlatformWallet() public {
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        new PDFactory(admin, address(0), BASE_URI);
    }

    // ─── Whitelist ───────────────────────────────────────────────────────

    function test_WhitelistArtist_OnlyAdmin() public {
        vm.prank(random);
        vm.expectRevert(PDFactory.NotAdmin.selector);
        factory.whitelistArtist(artist);
    }

    function test_WhitelistArtist_Success() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);
        assertTrue(factory.whitelistedArtists(artist));
    }

    function test_WhitelistArtist_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        factory.whitelistArtist(address(0));
    }

    function test_RemoveArtist_RevertsOnZero() public {
        // Consistency fix — removeArtist now validates zero address like whitelistArtist
        vm.prank(admin);
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        factory.removeArtist(address(0));
    }

    function test_RemoveArtist_RemovesWhitelist() public {
        vm.startPrank(admin);
        factory.whitelistArtist(artist);
        factory.removeArtist(artist);
        vm.stopPrank();
        assertFalse(factory.whitelistedArtists(artist));
    }

    // ─── Create Collection ───────────────────────────────────────────────

    function test_CreateCollection_RevertsIfNotWhitelisted() public {
        vm.prank(artist);
        vm.expectRevert(PDFactory.ArtistNotWhitelisted.selector);
        factory.createCollection("Kiki", "KIKI", 2222, 0.011 ether, _sampleScript());
    }

    function test_CreateCollection_RevertsOnZeroSupply() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        vm.prank(artist);
        vm.expectRevert(PDFactory.MaxSupplyZero.selector);
        factory.createCollection("Kiki", "KIKI", 0, 0.011 ether, _sampleScript());
    }

    function test_CreateCollection_RevertsOnSupplyAboveCap() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        vm.prank(artist);
        vm.expectRevert(PDFactory.MaxSupplyExceeded.selector);
        factory.createCollection("Kiki", "KIKI", 10_001, 0.011 ether, _sampleScript());
    }

    function test_CreateCollection_RevertsOnNoScript() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        bytes[] memory empty = new bytes[](0);
        vm.prank(artist);
        vm.expectRevert(PDFactory.NoScriptData.selector);
        factory.createCollection("Kiki", "KIKI", 2222, 0.011 ether, empty);
    }

    function test_CreateCollection_Success() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        address collection = _createSampleCollection(artist);
        assertTrue(collection != address(0));
        assertTrue(factory.isCollection(collection));
        assertEq(factory.collectionCount(), 1);
        assertEq(factory.artistCollectionCount(artist), 1);
        assertEq(factory.getArtistCollections(artist)[0], collection);
    }

    function test_CreateCollection_SupplyAtCapWorks() public {
        // Exactly 10k is allowed; the error fires above the cap.
        vm.prank(admin);
        factory.whitelistArtist(artist);

        vm.prank(artist);
        address collection =
            factory.createCollection("Max", "MAX", 10_000, 0.01 ether, _sampleScript());
        assertTrue(collection != address(0));
    }

    // ─── Cooldown ────────────────────────────────────────────────────────

    function test_Cooldown_FirstDeployHasNone() public view {
        assertEq(factory.cooldownRemaining(artist), 0);
    }

    function test_Cooldown_EnforcedOnSecondDeploy() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        _createSampleCollection(artist);

        // Immediate second deploy — should revert
        vm.prank(artist);
        vm.expectRevert(); // CooldownActive with data — using generic revert
        factory.createCollection("Kiki2", "K2", 2222, 0.011 ether, _sampleScript());
    }

    function test_Cooldown_AllowsDeployAfter60Days() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        _createSampleCollection(artist);

        // Warp forward 60 days + 1s
        vm.warp(block.timestamp + 60 days + 1);

        address c2 = _createSampleCollection(artist);
        assertTrue(c2 != address(0));
        assertEq(factory.artistCollectionCount(artist), 2);
    }

    function test_Cooldown_IsGlobalPerArtist_NotPerCollection() public {
        vm.startPrank(admin);
        factory.whitelistArtist(artist);
        vm.stopPrank();

        _createSampleCollection(artist);

        // 59 days later still blocked
        vm.warp(block.timestamp + 59 days);
        vm.prank(artist);
        vm.expectRevert();
        factory.createCollection("Kiki2", "K2", 2222, 0.011 ether, _sampleScript());
    }

    function test_Cooldown_DoesNotAffectDifferentArtist() public {
        vm.startPrank(admin);
        factory.whitelistArtist(artist);
        factory.whitelistArtist(artist2);
        vm.stopPrank();

        _createSampleCollection(artist);
        // Second artist can deploy immediately
        address c2 = _createSampleCollection(artist2);
        assertTrue(c2 != address(0));
    }

    function test_CanCreateCollection_View() public {
        // Not whitelisted
        assertFalse(factory.canCreateCollection(artist));

        vm.prank(admin);
        factory.whitelistArtist(artist);

        // Whitelisted, no prior deploy
        assertTrue(factory.canCreateCollection(artist));

        _createSampleCollection(artist);
        // Whitelisted, on cooldown
        assertFalse(factory.canCreateCollection(artist));

        vm.warp(block.timestamp + 60 days + 1);
        assertTrue(factory.canCreateCollection(artist));
    }

    // ─── Admin Ops ───────────────────────────────────────────────────────

    function test_TransferAdmin_Success() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        factory.transferAdmin(newAdmin);
        assertEq(factory.admin(), newAdmin);

        // Old admin locked out
        vm.prank(admin);
        vm.expectRevert(PDFactory.NotAdmin.selector);
        factory.whitelistArtist(artist);

        // New admin works
        vm.prank(newAdmin);
        factory.whitelistArtist(artist);
        assertTrue(factory.whitelistedArtists(artist));
    }

    function test_SetPlatformWallet_UpdatesAddress() public {
        address newWallet = makeAddr("newWallet");
        vm.prank(admin);
        factory.setPlatformWallet(newWallet);
        assertEq(factory.platformWallet(), newWallet);
    }

    function test_SetBaseTokenURI_Updates() public {
        string memory newURI = "https://new.example.com/token/";
        vm.prank(admin);
        factory.setBaseTokenURI(newURI);
        assertEq(factory.baseTokenURI(), newURI);
    }

    // ─── Withdraw ────────────────────────────────────────────────────────

    function test_WithdrawFrom_NoOpOnEmptyCollection() public {
        // Fix verified: withdrawing from a collection with 0 fees no longer reverts
        vm.prank(admin);
        factory.whitelistArtist(artist);
        address collection = _createSampleCollection(artist);

        // No mints yet — no fees accumulated
        vm.prank(admin);
        factory.withdrawFrom(collection); // must not revert
    }

    function test_WithdrawFrom_SweepsFees() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);
        address collection = _createSampleCollection(artist);

        // Mint 10 tokens at 0.011 ETH each = 0.11 ETH
        // Platform fee = 5% = 0.0055 ETH
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        PDCollection(collection).mint{value: 0.11 ether}(10);

        uint256 platformBefore = platformWallet.balance;

        vm.prank(admin);
        factory.withdrawFrom(collection);

        assertEq(platformWallet.balance, platformBefore + 0.0055 ether);
    }

    function test_BatchWithdrawRange_Works() public {
        vm.startPrank(admin);
        factory.whitelistArtist(artist);
        factory.whitelistArtist(artist2);
        vm.stopPrank();

        address c1 = _createSampleCollection(artist);
        address c2 = _createSampleCollection(artist2);

        // Mint from both — 0.011 * 10 = 0.11 per collection, 5% platform = 0.0055 each
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        PDCollection(c1).mint{value: 0.11 ether}(10);
        vm.prank(buyer);
        PDCollection(c2).mint{value: 0.11 ether}(10);

        uint256 platformBefore = platformWallet.balance;
        vm.prank(admin);
        factory.batchWithdrawRange(0, 2);

        assertEq(platformWallet.balance, platformBefore + 0.011 ether); // 0.0055 * 2
    }

    function test_BatchWithdrawRange_ClampsEnd() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);
        _createSampleCollection(artist);

        // Request end = 100 but only 1 collection exists — must not revert, just clamp
        vm.prank(admin);
        factory.batchWithdrawRange(0, 100);
    }

    function test_BatchWithdrawRange_RevertsOnInvalidRange() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);
        _createSampleCollection(artist);

        vm.prank(admin);
        vm.expectRevert(PDFactory.InvalidRange.selector);
        factory.batchWithdrawRange(5, 5); // start >= end after clamp
    }
}
