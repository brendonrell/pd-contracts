// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PDFactory} from "../src/PDFactory.sol";
import {PDProject} from "../src/PDProject.sol";

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

    function _createSampleProject(address _artist) internal returns (address project) {
        vm.prank(_artist);
        project = factory.createProject("Kiki", "KIKI", 2222, 0.011 ether, _sampleScript());
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

    // ─── Create Project ──────────────────────────────────────────────────

    function test_CreateProject_RevertsIfNotWhitelisted() public {
        vm.prank(artist);
        vm.expectRevert(PDFactory.ArtistNotWhitelisted.selector);
        factory.createProject("Kiki", "KIKI", 2222, 0.011 ether, _sampleScript());
    }

    function test_CreateProject_RevertsOnZeroSupply() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        vm.prank(artist);
        vm.expectRevert(PDFactory.MaxSupplyZero.selector);
        factory.createProject("Kiki", "KIKI", 0, 0.011 ether, _sampleScript());
    }

    function test_CreateProject_RevertsOnSupplyAboveCap() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        vm.prank(artist);
        vm.expectRevert(PDFactory.MaxSupplyExceeded.selector);
        factory.createProject("Kiki", "KIKI", 10_001, 0.011 ether, _sampleScript());
    }

    function test_CreateProject_RevertsOnNoScript() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        bytes[] memory empty = new bytes[](0);
        vm.prank(artist);
        vm.expectRevert(PDFactory.NoScriptData.selector);
        factory.createProject("Kiki", "KIKI", 2222, 0.011 ether, empty);
    }

    function test_CreateProject_Success() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        address project = _createSampleProject(artist);
        assertTrue(project != address(0));
        assertTrue(factory.isProject(project));
        assertEq(factory.projectCount(), 1);
        assertEq(factory.artistProjectCount(artist), 1);
        assertEq(factory.getArtistProjects(artist)[0], project);
    }

    function test_CreateProject_SupplyAtCapWorks() public {
        // Exactly 10k is allowed; the error fires above the cap.
        vm.prank(admin);
        factory.whitelistArtist(artist);

        vm.prank(artist);
        address project =
            factory.createProject("Max", "MAX", 10_000, 0.01 ether, _sampleScript());
        assertTrue(project != address(0));
    }

    // ─── Cooldown ────────────────────────────────────────────────────────

    function test_Cooldown_FirstDeployHasNone() public view {
        assertEq(factory.cooldownRemaining(artist), 0);
    }

    function test_Cooldown_EnforcedOnSecondDeploy() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        _createSampleProject(artist);

        // Immediate second deploy — should revert
        vm.prank(artist);
        vm.expectRevert(); // CooldownActive with data — using generic revert
        factory.createProject("Kiki2", "K2", 2222, 0.011 ether, _sampleScript());
    }

    function test_Cooldown_AllowsDeployAfter60Days() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);

        _createSampleProject(artist);

        // Warp forward 60 days + 1s
        vm.warp(block.timestamp + 60 days + 1);

        address c2 = _createSampleProject(artist);
        assertTrue(c2 != address(0));
        assertEq(factory.artistProjectCount(artist), 2);
    }

    function test_Cooldown_IsGlobalPerArtist_NotPerProject() public {
        vm.startPrank(admin);
        factory.whitelistArtist(artist);
        vm.stopPrank();

        _createSampleProject(artist);

        // 59 days later still blocked
        vm.warp(block.timestamp + 59 days);
        vm.prank(artist);
        vm.expectRevert();
        factory.createProject("Kiki2", "K2", 2222, 0.011 ether, _sampleScript());
    }

    function test_Cooldown_DoesNotAffectDifferentArtist() public {
        vm.startPrank(admin);
        factory.whitelistArtist(artist);
        factory.whitelistArtist(artist2);
        vm.stopPrank();

        _createSampleProject(artist);
        // Second artist can deploy immediately
        address c2 = _createSampleProject(artist2);
        assertTrue(c2 != address(0));
    }

    function test_CanCreateProject_View() public {
        // Not whitelisted
        assertFalse(factory.canCreateProject(artist));

        vm.prank(admin);
        factory.whitelistArtist(artist);

        // Whitelisted, no prior deploy
        assertTrue(factory.canCreateProject(artist));

        _createSampleProject(artist);
        // Whitelisted, on cooldown
        assertFalse(factory.canCreateProject(artist));

        vm.warp(block.timestamp + 60 days + 1);
        assertTrue(factory.canCreateProject(artist));
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

    function test_WithdrawFrom_NoOpOnEmptyProject() public {
        // Fix verified: withdrawing from a Project with 0 fees no longer reverts
        vm.prank(admin);
        factory.whitelistArtist(artist);
        address project = _createSampleProject(artist);

        // No mints yet — no fees accumulated
        vm.prank(admin);
        factory.withdrawFrom(project); // must not revert
    }

    function test_WithdrawFrom_SweepsFees() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);
        address project = _createSampleProject(artist);

        // Mint 10 tokens at 0.011 ETH each = 0.11 ETH
        // Platform fee = 5% = 0.0055 ETH
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        PDProject(project).mint{value: 0.11 ether}(10);

        uint256 platformBefore = platformWallet.balance;

        vm.prank(admin);
        factory.withdrawFrom(project);

        assertEq(platformWallet.balance, platformBefore + 0.0055 ether);
    }

    function test_BatchWithdrawRange_Works() public {
        vm.startPrank(admin);
        factory.whitelistArtist(artist);
        factory.whitelistArtist(artist2);
        vm.stopPrank();

        address c1 = _createSampleProject(artist);
        address c2 = _createSampleProject(artist2);

        // Mint from both — 0.011 * 10 = 0.11 per Project, 5% platform = 0.0055 each
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        PDProject(c1).mint{value: 0.11 ether}(10);
        vm.prank(buyer);
        PDProject(c2).mint{value: 0.11 ether}(10);

        uint256 platformBefore = platformWallet.balance;
        vm.prank(admin);
        factory.batchWithdrawRange(0, 2);

        assertEq(platformWallet.balance, platformBefore + 0.011 ether); // 0.0055 * 2
    }

    function test_BatchWithdrawRange_ClampsEnd() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);
        _createSampleProject(artist);

        // Request end = 100 but only 1 Project exists — must not revert, just clamp
        vm.prank(admin);
        factory.batchWithdrawRange(0, 100);
    }

    function test_BatchWithdrawRange_RevertsOnInvalidRange() public {
        vm.prank(admin);
        factory.whitelistArtist(artist);
        _createSampleProject(artist);

        vm.prank(admin);
        vm.expectRevert(PDFactory.InvalidRange.selector);
        factory.batchWithdrawRange(5, 5); // start >= end after clamp
    }
}
