// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PDFactory} from "../src/PDFactory.sol";
import {PDProject} from "../src/PDProject.sol";
import {
    MockChainlinkAggregator,
    MockUniswapV3Pool,
    MockWETH,
    MockUSDC
} from "./mocks/Mocks.sol";

contract PDFactoryTest is Test {
    PDFactory factory;

    address admin = makeAddr("admin");
    address platformWallet = makeAddr("platformWallet");
    address storageFeeWallet = makeAddr("storageFeeWallet");
    address storageFeeWriter = makeAddr("storageFeeWriter");
    address artist1 = makeAddr("artist1");
    address artist2 = makeAddr("artist2");
    address rando = makeAddr("rando");

    address chainlink;
    address pool;
    address weth;
    address usdc;

    function setUp() public {
        chainlink = address(new MockChainlinkAggregator(int256(3000e8), block.timestamp));
        pool = address(new MockUniswapV3Pool(int24(-196250)));
        weth = address(new MockWETH());
        usdc = address(new MockUSDC());

        factory = new PDFactory(
            admin,
            platformWallet,
            storageFeeWallet,
            storageFeeWriter,
            chainlink,
            pool,
            weth,
            usdc
        );
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    function test_Constructor_SetsAllAddresses() public view {
        assertEq(factory.admin(), admin);
        assertEq(factory.platformWallet(), platformWallet);
        assertEq(factory.storageFeeWallet(), storageFeeWallet);
        assertEq(factory.storageFeeWriter(), storageFeeWriter);
        assertEq(factory.chainlinkFeed(), chainlink);
        assertEq(factory.uniswapV3Pool(), pool);
        assertEq(factory.weth(), weth);
        assertEq(factory.usdc(), usdc);
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        new PDFactory(address(0), platformWallet, storageFeeWallet, storageFeeWriter, chainlink, pool, weth, usdc);
    }

    function test_Constructor_RevertsOnZeroPlatformWallet() public {
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        new PDFactory(admin, address(0), storageFeeWallet, storageFeeWriter, chainlink, pool, weth, usdc);
    }

    function test_Constructor_RevertsOnZeroStorageFeeWallet() public {
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        new PDFactory(admin, platformWallet, address(0), storageFeeWriter, chainlink, pool, weth, usdc);
    }

    function test_Constructor_RevertsOnZeroStorageFeeWriter() public {
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        new PDFactory(admin, platformWallet, storageFeeWallet, address(0), chainlink, pool, weth, usdc);
    }

    function test_Constructor_RevertsOnZeroChainlink() public {
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        new PDFactory(admin, platformWallet, storageFeeWallet, storageFeeWriter, address(0), pool, weth, usdc);
    }

    function test_Constructor_RevertsOnZeroPool() public {
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        new PDFactory(admin, platformWallet, storageFeeWallet, storageFeeWriter, chainlink, address(0), weth, usdc);
    }

    function test_Constructor_RevertsOnZeroWeth() public {
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        new PDFactory(admin, platformWallet, storageFeeWallet, storageFeeWriter, chainlink, pool, address(0), usdc);
    }

    function test_Constructor_RevertsOnZeroUsdc() public {
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        new PDFactory(admin, platformWallet, storageFeeWallet, storageFeeWriter, chainlink, pool, weth, address(0));
    }

    // ─── Whitelist ───────────────────────────────────────────────────────

    function test_WhitelistArtist_OnlyAdmin() public {
        vm.prank(rando);
        vm.expectRevert(PDFactory.NotAdmin.selector);
        factory.whitelistArtist(artist1);
    }

    function test_WhitelistArtist_Success() public {
        vm.prank(admin);
        factory.whitelistArtist(artist1);
        assertTrue(factory.whitelistedArtists(artist1));
    }

    function test_WhitelistArtist_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        factory.whitelistArtist(address(0));
    }

    function test_RemoveArtist_OnlyAdmin() public {
        vm.prank(admin);
        factory.whitelistArtist(artist1);
        vm.prank(rando);
        vm.expectRevert(PDFactory.NotAdmin.selector);
        factory.removeArtist(artist1);
    }

    function test_RemoveArtist_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        factory.removeArtist(address(0));
    }

    function test_RemoveArtist_ClearsWhitelist() public {
        vm.startPrank(admin);
        factory.whitelistArtist(artist1);
        factory.removeArtist(artist1);
        vm.stopPrank();
        assertFalse(factory.whitelistedArtists(artist1));
    }

    // ─── createProject ───────────────────────────────────────────────────

    function _whitelist(address a) internal {
        vm.prank(admin);
        factory.whitelistArtist(a);
    }

    function _scriptChunks() internal pure returns (bytes[] memory chunks) {
        chunks = new bytes[](1);
        chunks[0] = bytes("function setup(){}function draw(){}");
    }

    function test_CreateProject_RevertsIfNotWhitelisted() public {
        vm.prank(artist1);
        vm.expectRevert(PDFactory.ArtistNotWhitelisted.selector);
        factory.createProject("Drop", "DROP", 100, 0.01 ether, _scriptChunks(), "desc");
    }

    function test_CreateProject_RevertsOnZeroSupply() public {
        _whitelist(artist1);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.MaxSupplyZero.selector);
        factory.createProject("Drop", "DROP", 0, 0.01 ether, _scriptChunks(), "desc");
    }

    function test_CreateProject_RevertsAboveSupplyCap() public {
        _whitelist(artist1);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.MaxSupplyExceeded.selector);
        factory.createProject("Drop", "DROP", 10_001, 0.01 ether, _scriptChunks(), "desc");
    }

    function test_CreateProject_RevertsWithoutScript() public {
        _whitelist(artist1);
        bytes[] memory empty = new bytes[](0);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.NoScriptData.selector);
        factory.createProject("Drop", "DROP", 100, 0.01 ether, empty, "desc");
    }

    // ─── createProject: JSON-character validation ────────────────────────

    function test_CreateProject_RevertsOnQuoteInName() public {
        _whitelist(artist1);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.InvalidCharacter.selector);
        factory.createProject('Bad"Name', "DROP", 100, 0.01 ether, _scriptChunks(), "ok");
    }

    function test_CreateProject_RevertsOnBackslashInName() public {
        _whitelist(artist1);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.InvalidCharacter.selector);
        // Solidity string literal: "Bad\\Name" embeds a single backslash byte.
        factory.createProject("Bad\\Name", "DROP", 100, 0.01 ether, _scriptChunks(), "ok");
    }

    function test_CreateProject_RevertsOnNewlineInName() public {
        _whitelist(artist1);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.InvalidCharacter.selector);
        factory.createProject("Bad\nName", "DROP", 100, 0.01 ether, _scriptChunks(), "ok");
    }

    function test_CreateProject_RevertsOnNullByteInName() public {
        _whitelist(artist1);
        // Construct a name with a 0x00 byte.
        bytes memory raw = bytes("BadName");
        raw[3] = 0x00;
        string memory bad = string(raw);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.InvalidCharacter.selector);
        factory.createProject(bad, "DROP", 100, 0.01 ether, _scriptChunks(), "ok");
    }

    function test_CreateProject_RevertsOnDelByteInName() public {
        _whitelist(artist1);
        // Construct a name with a 0x7F (DEL) byte.
        bytes memory raw = bytes("BadName");
        raw[3] = 0x7F;
        string memory bad = string(raw);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.InvalidCharacter.selector);
        factory.createProject(bad, "DROP", 100, 0.01 ether, _scriptChunks(), "ok");
    }

    function test_CreateProject_RevertsOnQuoteInDescription() public {
        _whitelist(artist1);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.InvalidCharacter.selector);
        factory.createProject("Drop", "DROP", 100, 0.01 ether, _scriptChunks(), 'has "quote"');
    }

    function test_CreateProject_RevertsOnBackslashInDescription() public {
        _whitelist(artist1);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.InvalidCharacter.selector);
        factory.createProject("Drop", "DROP", 100, 0.01 ether, _scriptChunks(), "back\\slash");
    }

    function test_CreateProject_RevertsOnControlByteInDescription() public {
        _whitelist(artist1);
        bytes memory raw = bytes("multi line");
        raw[5] = 0x09; // TAB
        string memory bad = string(raw);
        vm.prank(artist1);
        vm.expectRevert(PDFactory.InvalidCharacter.selector);
        factory.createProject("Drop", "DROP", 100, 0.01 ether, _scriptChunks(), bad);
    }

    function test_CreateProject_AcceptsUtf8Multibyte() public {
        // UTF-8 multibyte characters (>= 0x80) must pass through validation.
        // "naïve — café" exercises 0xC3 0xAF (ï), 0xE2 0x80 0x94 (—), 0xC3 0xA9 (é).
        _whitelist(artist1);
        vm.prank(artist1);
        address proj = factory.createProject(
            unicode"Naïve",
            "DROP",
            100,
            0.01 ether,
            _scriptChunks(),
            unicode"café — drop"
        );
        assertTrue(factory.isProject(proj));
    }

    function test_CreateProject_AcceptsEmptyDescription() public {
        _whitelist(artist1);
        vm.prank(artist1);
        address proj = factory.createProject("Drop", "DROP", 100, 0.01 ether, _scriptChunks(), "");
        assertTrue(factory.isProject(proj));
    }

    function test_CreateProject_Success() public {
        _whitelist(artist1);
        vm.prank(artist1);
        address proj = factory.createProject("Drop", "DROP", 100, 0.01 ether, _scriptChunks(), "desc");

        assertTrue(factory.isProject(proj));
        assertEq(factory.lastProjectTimestamp(artist1), block.timestamp);
        assertEq(PDProject(proj).artist(), artist1);
        assertEq(PDProject(proj).maxSupply(), 100);
        assertEq(PDProject(proj).mintPrice(), 0.01 ether);
        assertEq(PDProject(proj).description(), "desc");
        assertEq(PDProject(proj).factory(), address(factory));
    }

    function test_CreateProject_AtCap_Succeeds() public {
        _whitelist(artist1);
        vm.prank(artist1);
        address proj = factory.createProject("Cap", "CAP", 10_000, 0.01 ether, _scriptChunks(), "");
        assertEq(PDProject(proj).maxSupply(), 10_000);
    }

    // ─── Cooldown ────────────────────────────────────────────────────────

    function test_Cooldown_NoneOnFirstProject() public {
        _whitelist(artist1);
        assertTrue(factory.canCreateProject(artist1));
        vm.prank(artist1);
        factory.createProject("A", "A", 10, 0.01 ether, _scriptChunks(), "");
    }

    function test_Cooldown_BlocksSecondProjectImmediately() public {
        _whitelist(artist1);
        vm.prank(artist1);
        factory.createProject("A", "A", 10, 0.01 ether, _scriptChunks(), "");

        assertFalse(factory.canCreateProject(artist1));

        vm.prank(artist1);
        vm.expectRevert(
            abi.encodeWithSelector(PDFactory.CooldownActive.selector, block.timestamp + 60 days)
        );
        factory.createProject("B", "B", 10, 0.01 ether, _scriptChunks(), "");
    }

    function test_Cooldown_AllowsAfter60Days() public {
        _whitelist(artist1);
        vm.prank(artist1);
        factory.createProject("A", "A", 10, 0.01 ether, _scriptChunks(), "");

        vm.warp(block.timestamp + 60 days);
        assertTrue(factory.canCreateProject(artist1));

        vm.prank(artist1);
        factory.createProject("B", "B", 10, 0.01 ether, _scriptChunks(), "");
    }

    function test_Cooldown_IsPerArtist() public {
        _whitelist(artist1);
        _whitelist(artist2);

        vm.prank(artist1);
        factory.createProject("A", "A", 10, 0.01 ether, _scriptChunks(), "");

        // artist2 is unaffected by artist1's cooldown.
        assertTrue(factory.canCreateProject(artist2));
        vm.prank(artist2);
        factory.createProject("B", "B", 10, 0.01 ether, _scriptChunks(), "");
    }

    function test_CanCreateProject_FalseForUnwhitelisted() public view {
        assertFalse(factory.canCreateProject(rando));
    }

    // ─── Admin Rotation ──────────────────────────────────────────────────

    function test_TransferAdmin_OnlyAdmin() public {
        vm.prank(rando);
        vm.expectRevert(PDFactory.NotAdmin.selector);
        factory.transferAdmin(rando);
    }

    function test_TransferAdmin_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        factory.transferAdmin(address(0));
    }

    function test_TransferAdmin_Success() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        factory.transferAdmin(newAdmin);
        assertEq(factory.admin(), newAdmin);

        // Old admin no longer has authority.
        vm.prank(admin);
        vm.expectRevert(PDFactory.NotAdmin.selector);
        factory.whitelistArtist(artist1);
    }

    function test_SetPlatformWallet_OnlyAdmin() public {
        vm.prank(rando);
        vm.expectRevert(PDFactory.NotAdmin.selector);
        factory.setPlatformWallet(rando);
    }

    function test_SetPlatformWallet_Success() public {
        address newWallet = makeAddr("newPlatform");
        vm.prank(admin);
        factory.setPlatformWallet(newWallet);
        assertEq(factory.platformWallet(), newWallet);
    }

    function test_SetPlatformWallet_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        factory.setPlatformWallet(address(0));
    }

    function test_SetStorageFeeWallet_OnlyAdmin() public {
        vm.prank(rando);
        vm.expectRevert(PDFactory.NotAdmin.selector);
        factory.setStorageFeeWallet(rando);
    }

    function test_SetStorageFeeWallet_Success() public {
        address newWallet = makeAddr("newStorage");
        vm.prank(admin);
        factory.setStorageFeeWallet(newWallet);
        assertEq(factory.storageFeeWallet(), newWallet);
    }

    function test_SetStorageFeeWallet_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        factory.setStorageFeeWallet(address(0));
    }

    function test_SetStorageFeeWriter_OnlyAdmin() public {
        vm.prank(rando);
        vm.expectRevert(PDFactory.NotAdmin.selector);
        factory.setStorageFeeWriter(rando);
    }

    function test_SetStorageFeeWriter_Success() public {
        address newWriter = makeAddr("newWriter");
        vm.prank(admin);
        factory.setStorageFeeWriter(newWriter);
        assertEq(factory.storageFeeWriter(), newWriter);
    }

    function test_SetStorageFeeWriter_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(PDFactory.ZeroAddress.selector);
        factory.setStorageFeeWriter(address(0));
    }
}
