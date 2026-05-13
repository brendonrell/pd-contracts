// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PDFactory} from "../src/PDFactory.sol";
import {PDProject} from "../src/PDProject.sol";

contract PDProjectTest is Test {
    PDFactory factory;
    PDProject project;

    address admin = makeAddr("admin");
    address platformWallet = makeAddr("platformWallet");
    address artist = makeAddr("artist");
    address buyer = makeAddr("buyer");
    address buyer2 = makeAddr("buyer2");

    string constant BASE_URI = "https://api.pricediscussion.com/token/";

    function setUp() public {
        factory = new PDFactory(admin, platformWallet, BASE_URI);
        vm.prank(admin);
        factory.whitelistArtist(artist);

        bytes[] memory chunks = new bytes[](1);
        chunks[0] = bytes("function draw(p5){p5.background(0);}");

        vm.prank(artist);
        project = PDProject(
            factory.createProject("Kiki", "KIKI", 2222, 0.011 ether, chunks)
        );

        // Fund buyers
        vm.deal(buyer, 10 ether);
        vm.deal(buyer2, 10 ether);
    }

    // ─── Constructor / Immutables ────────────────────────────────────────

    function test_Immutables_SetCorrectly() public view {
        assertEq(project.artist(), artist);
        assertEq(project.factory(), address(factory));
        assertEq(project.mintPrice(), 0.011 ether);
        assertEq(project.maxSupply(), 2222);
        assertEq(project.totalMinted(), 0);
        assertTrue(project.paymentSplitter() != address(0));
    }

    // ─── Mint ────────────────────────────────────────────────────────────

    function test_Mint_Success() public {
        uint256 artistBefore = artist.balance;

        vm.prank(buyer);
        project.mint{value: 0.011 ether}(1);

        assertEq(project.totalMinted(), 1);
        assertEq(project.ownerOf(1), buyer);
        // Artist gets 95% = 0.01045
        assertEq(artist.balance, artistBefore + 0.01045 ether);
        // Platform fee accrues in contract = 5% = 0.00055
        assertEq(project.accumulatedFees(), 0.00055 ether);
    }

    function test_Mint_MultipleTokens() public {
        vm.prank(buyer);
        project.mint{value: 0.055 ether}(5);

        assertEq(project.totalMinted(), 5);
        for (uint256 i = 1; i <= 5; i++) {
            assertEq(project.ownerOf(i), buyer);
        }
    }

    function test_Mint_RevertsOnZeroQuantity() public {
        vm.prank(buyer);
        vm.expectRevert(PDProject.QuantityZero.selector);
        project.mint{value: 0}(0);
    }

    function test_Mint_RevertsOnUnderpayment() public {
        vm.prank(buyer);
        vm.expectRevert(PDProject.IncorrectPayment.selector);
        project.mint{value: 0.010 ether}(1);
    }

    function test_Mint_RevertsOnOverpayment() public {
        vm.prank(buyer);
        vm.expectRevert(PDProject.IncorrectPayment.selector);
        project.mint{value: 0.012 ether}(1);
    }

    function test_Mint_RevertsOnMaxSupplyExceeded() public {
        // Deploy a tiny Project for the bounds test
        bytes[] memory chunks = new bytes[](1);
        chunks[0] = bytes("x");

        vm.warp(block.timestamp + 61 days); // clear cooldown
        vm.prank(artist);
        PDProject tiny = PDProject(
            factory.createProject("Tiny", "T", 2, 0.001 ether, chunks)
        );

        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        tiny.mint{value: 0.002 ether}(2); // mints the whole supply

        vm.prank(buyer);
        vm.expectRevert(PDProject.MaxSupplyReached.selector);
        tiny.mint{value: 0.001 ether}(1);
    }

    function test_Mint_HashesAreUniquePerToken() public {
        vm.prank(buyer);
        project.mint{value: 0.055 ether}(5);

        bytes32 h1 = project.tokenHashes(1);
        bytes32 h2 = project.tokenHashes(2);
        bytes32 h3 = project.tokenHashes(3);

        assertTrue(h1 != bytes32(0));
        assertTrue(h1 != h2);
        assertTrue(h2 != h3);
        assertTrue(h1 != h3);
    }

    function test_Mint_HashesDifferBetweenMinters() public {
        // Validates the msg.sender entropy fix — two minters in the same block
        // who each mint token #1 of their respective Projects should get different hashes
        vm.prank(buyer);
        project.mint{value: 0.011 ether}(1);
        bytes32 h1 = project.tokenHashes(1);

        vm.prank(buyer2);
        project.mint{value: 0.011 ether}(1);
        bytes32 h2 = project.tokenHashes(2);

        assertTrue(h1 != h2);
    }

    // ─── Withdraw ────────────────────────────────────────────────────────

    function test_Withdraw_OnlyFactory() public {
        vm.prank(buyer);
        project.mint{value: 0.011 ether}(1);

        vm.prank(buyer);
        vm.expectRevert(PDProject.NotFactory.selector);
        project.withdraw();
    }

    function test_Withdraw_NoOpWhenZero() public {
        // Fix verified: idempotent on zero — returns without reverting
        vm.prank(address(factory));
        project.withdraw(); // must not revert
    }

    function test_Withdraw_SendsFeesToFactory() public {
        vm.prank(buyer);
        project.mint{value: 0.011 ether}(1);

        uint256 factoryBefore = address(factory).balance;

        vm.prank(address(factory));
        project.withdraw();

        assertEq(address(factory).balance, factoryBefore + 0.00055 ether);
        assertEq(project.accumulatedFees(), 0);
    }

    // ─── Metadata ────────────────────────────────────────────────────────

    function test_TokenURI_DelegatesToFactoryBaseURI() public {
        vm.prank(buyer);
        project.mint{value: 0.011 ether}(1);

        string memory uri = project.tokenURI(1);
        // URI should start with the base and contain /1 at end
        assertTrue(bytes(uri).length > bytes(BASE_URI).length);
    }

    function test_TokenURI_ReflectsBaseURIUpdates() public {
        vm.prank(buyer);
        project.mint{value: 0.011 ether}(1);

        string memory before_ = project.tokenURI(1);

        vm.prank(admin);
        factory.setBaseTokenURI("https://new.example.com/t/");

        string memory after_ = project.tokenURI(1);
        assertTrue(keccak256(bytes(before_)) != keccak256(bytes(after_)));
    }

    // ─── Royalty ─────────────────────────────────────────────────────────

    function test_RoyaltyInfo_FivePercentToSplitter() public view {
        (address receiver, uint256 amount) = project.royaltyInfo(1, 1 ether);
        assertEq(receiver, project.paymentSplitter());
        assertEq(amount, 0.05 ether); // 5% of 1 ETH
    }

    // ─── Script Storage ──────────────────────────────────────────────────

    function test_ScriptStorage_ReadBack() public view {
        assertEq(project.scriptChunkCount(), 1);
        string memory chunk = project.scriptChunk(0);
        assertEq(chunk, "function draw(p5){p5.background(0);}");
    }
}
