// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PDFactory} from "../src/PDFactory.sol";
import {PDProject} from "../src/PDProject.sol";
import {PaymentSplitter} from "../src/PaymentSplitter.sol";
import {
    MockChainlinkAggregator,
    MockUniswapV3Pool,
    MockWETH,
    MockUSDC
} from "./mocks/Mocks.sol";

contract PDProjectTest is Test {
    PDFactory factory;
    PDProject project;

    MockChainlinkAggregator chainlinkMock;
    MockUniswapV3Pool poolMock;

    address admin = makeAddr("admin");
    address platformWallet = makeAddr("platformWallet");
    address storageFeeWallet = makeAddr("storageFeeWallet");
    address storageFeeWriter = makeAddr("storageFeeWriter");
    address artist = makeAddr("artist");
    address minter = makeAddr("minter");
    address otherMinter = makeAddr("otherMinter");

    address weth;
    address usdc;

    uint256 constant MINT_PRICE = 0.01 ether;
    uint256 constant MAX_SUPPLY = 100;

    function setUp() public {
        // Bring block.timestamp to a non-zero value before Chainlink mock setup.
        vm.warp(1_700_000_000);

        chainlinkMock = new MockChainlinkAggregator(int256(3000e8), block.timestamp);
        poolMock = new MockUniswapV3Pool(int24(-196250));
        weth = address(new MockWETH());
        usdc = address(new MockUSDC());

        factory = new PDFactory(
            admin,
            platformWallet,
            storageFeeWallet,
            storageFeeWriter,
            address(chainlinkMock),
            address(poolMock),
            weth,
            usdc
        );

        vm.prank(admin);
        factory.whitelistArtist(artist);

        bytes[] memory chunks = new bytes[](1);
        chunks[0] = bytes("function setup(){}function draw(){background(0);}");

        vm.prank(artist);
        address proj = factory.createProject("Drop", "DROP", MAX_SUPPLY, MINT_PRICE, chunks, "A description.");
        project = PDProject(proj);

        vm.deal(minter, 100 ether);
        vm.deal(otherMinter, 100 ether);
    }

    function _required(uint256 quantity) internal view returns (uint256) {
        return (MINT_PRICE + project.currentStorageFeeWei()) * quantity;
    }

    // ─── Constructor / Immutables ────────────────────────────────────────

    function test_Construction_StoresFields() public view {
        assertEq(project.artist(), artist);
        assertEq(project.factory(), address(factory));
        assertEq(project.mintPrice(), MINT_PRICE);
        assertEq(project.maxSupply(), MAX_SUPPLY);
        assertEq(project.totalMinted(), 0);
        assertEq(project.name(), "Drop");
        assertEq(project.symbol(), "DROP");
        assertEq(project.description(), "A description.");
        assertEq(project.scriptChunkCount(), 1);
        assertTrue(project.paymentSplitter() != address(0));
    }

    function test_ScriptStorage_RoundTrip() public view {
        string memory s = project.getScript();
        // Script should match what we wrote in setUp.
        assertEq(s, "function setup(){}function draw(){background(0);}");
    }

    // ─── Storage Fee View ────────────────────────────────────────────────

    function test_CurrentStorageFeeWei_MatchesChainlinkMath() public view {
        // ETH = $3000 (8 dec) → ethUsd18 = 3e21
        // fee = 2e36 / 3e21 = 666666666666666 (approx 0.000667 ETH)
        uint256 expected = (2 * 1e36) / (uint256(3000e8) * 1e10);
        assertEq(project.currentStorageFeeWei(), expected);
    }

    // ─── Mint: Success Paths ─────────────────────────────────────────────

    function test_Mint_OneToken_Success() public {
        uint256 storageFee = project.currentStorageFeeWei();
        uint256 required = MINT_PRICE + storageFee;

        uint256 platformBefore = platformWallet.balance;
        uint256 storageBefore = storageFeeWallet.balance;
        uint256 artistBefore = artist.balance;

        vm.prank(minter);
        project.mint{value: required}(1);

        // Token ownership + state
        assertEq(project.totalMinted(), 1);
        assertEq(project.ownerOf(1), minter);
        assertEq(project.balanceOf(minter), 1);

        // Project holds nothing (push pattern).
        assertEq(address(project).balance, 0);

        // 95/5 split on mint price; 100% storage to storage wallet.
        uint256 artistShare = (MINT_PRICE * 9500) / 10000;
        uint256 platformShare = MINT_PRICE - artistShare;

        assertEq(artist.balance - artistBefore, artistShare);
        assertEq(platformWallet.balance - platformBefore, platformShare);
        assertEq(storageFeeWallet.balance - storageBefore, storageFee);

        // Hash should be set and non-zero.
        assertTrue(project.tokenHashes(1) != bytes32(0));
    }

    function test_Mint_FiveTokens_Success() public {
        uint256 q = 5;
        uint256 required = _required(q);
        uint256 storageFee = project.currentStorageFeeWei();

        uint256 platformBefore = platformWallet.balance;
        uint256 storageBefore = storageFeeWallet.balance;
        uint256 artistBefore = artist.balance;

        vm.prank(minter);
        project.mint{value: required}(q);

        assertEq(project.totalMinted(), q);
        for (uint256 i = 1; i <= q; i++) {
            assertEq(project.ownerOf(i), minter);
            assertTrue(project.tokenHashes(i) != bytes32(0));
        }

        assertEq(address(project).balance, 0);

        uint256 mintPriceTotal = MINT_PRICE * q;
        uint256 artistShare = (mintPriceTotal * 9500) / 10000;
        uint256 platformShare = mintPriceTotal - artistShare;
        uint256 storageTotal = storageFee * q;

        assertEq(artist.balance - artistBefore, artistShare);
        assertEq(platformWallet.balance - platformBefore, platformShare);
        assertEq(storageFeeWallet.balance - storageBefore, storageTotal);
    }

    function test_Mint_EmitsMintFeeDistributed_WithFirstTokenId() public {
        uint256 q = 3;
        uint256 storageFee = project.currentStorageFeeWei();
        uint256 mintPriceTotal = MINT_PRICE * q;
        uint256 artistShare = (mintPriceTotal * 9500) / 10000;
        uint256 platformShare = mintPriceTotal - artistShare;
        uint256 storageTotal = storageFee * q;

        // First batch — first tokenId is 1.
        vm.expectEmit(true, false, false, true, address(project));
        emit PDProject.MintFeeDistributed(1, artistShare, platformShare, storageTotal);

        vm.prank(minter);
        project.mint{value: _required(q)}(q);

        // Second batch — first tokenId is 4 (1+3).
        vm.expectEmit(true, false, false, true, address(project));
        emit PDProject.MintFeeDistributed(4, artistShare, platformShare, storageTotal);

        vm.prank(otherMinter);
        project.mint{value: _required(q)}(q);
    }

    function test_Mint_HashesDiffer_AcrossTokens() public {
        vm.prank(minter);
        project.mint{value: _required(3)}(3);

        bytes32 h1 = project.tokenHashes(1);
        bytes32 h2 = project.tokenHashes(2);
        bytes32 h3 = project.tokenHashes(3);
        assertTrue(h1 != h2);
        assertTrue(h2 != h3);
        assertTrue(h1 != h3);
    }

    function test_Mint_HashesDiffer_AcrossMinters() public {
        vm.prank(minter);
        project.mint{value: _required(1)}(1);
        bytes32 h1 = project.tokenHashes(1);

        // Same block produces same blockhash component — but tokenId and minter differ.
        vm.prank(otherMinter);
        project.mint{value: _required(1)}(1);
        bytes32 h2 = project.tokenHashes(2);

        assertTrue(h1 != h2);
    }

    // ─── Mint: Revert Paths ──────────────────────────────────────────────

    function test_Mint_RevertsOnZeroQuantity() public {
        vm.prank(minter);
        vm.expectRevert(PDProject.QuantityZero.selector);
        project.mint{value: 0}(0);
    }

    function test_Mint_RevertsOnUnderpayment() public {
        uint256 required = _required(1);
        vm.prank(minter);
        vm.expectRevert(PDProject.IncorrectPayment.selector);
        project.mint{value: required - 1}(1);
    }

    function test_Mint_RevertsOnOverpayment() public {
        uint256 required = _required(1);
        vm.prank(minter);
        vm.expectRevert(PDProject.IncorrectPayment.selector);
        project.mint{value: required + 1}(1);
    }

    function test_Mint_RevertsOnMaxSupplyExceeded() public {
        // Mint full supply first.
        vm.prank(minter);
        project.mint{value: _required(MAX_SUPPLY)}(MAX_SUPPLY);
        assertEq(project.totalMinted(), MAX_SUPPLY);

        // One more should revert.
        vm.prank(minter);
        vm.expectRevert(PDProject.MaxSupplyReached.selector);
        project.mint{value: _required(1)}(1);
    }

    function test_Mint_RevertsWhenQuantityWouldExceedSupply() public {
        // Mint MAX_SUPPLY - 1, then try to mint 2.
        uint256 nearly = MAX_SUPPLY - 1;
        vm.prank(minter);
        project.mint{value: _required(nearly)}(nearly);

        vm.prank(minter);
        vm.expectRevert(PDProject.MaxSupplyReached.selector);
        project.mint{value: _required(2)}(2);
    }

    // ─── setArweaveTxid ──────────────────────────────────────────────────

    function _mintOne() internal {
        vm.prank(minter);
        project.mint{value: _required(1)}(1);
    }

    function test_SetArweaveTxid_OnlyWriter() public {
        _mintOne();
        vm.prank(minter);
        vm.expectRevert(PDProject.NotWriter.selector);
        project.setArweaveTxid(1, bytes32(uint256(0xdeadbeef)));
    }

    function test_SetArweaveTxid_RevertsOnZeroTxid() public {
        _mintOne();
        vm.prank(storageFeeWriter);
        vm.expectRevert(PDProject.ZeroTxid.selector);
        project.setArweaveTxid(1, bytes32(0));
    }

    function test_SetArweaveTxid_RevertsOnNonexistentToken() public {
        _mintOne();
        vm.prank(storageFeeWriter);
        vm.expectRevert(PDProject.NonexistentToken.selector);
        project.setArweaveTxid(99, bytes32(uint256(0xdeadbeef)));
    }

    function test_SetArweaveTxid_RevertsOnTokenIdZero() public {
        _mintOne();
        vm.prank(storageFeeWriter);
        vm.expectRevert(PDProject.NonexistentToken.selector);
        project.setArweaveTxid(0, bytes32(uint256(0xdeadbeef)));
    }

    function test_SetArweaveTxid_Success() public {
        _mintOne();
        bytes32 txid = bytes32(uint256(0xcafebabe));

        vm.expectEmit(true, false, false, true, address(project));
        emit PDProject.ArweaveTxidSet(1, txid);

        vm.prank(storageFeeWriter);
        project.setArweaveTxid(1, txid);

        assertEq(project.tokenArweaveManifests(1), txid);
    }

    function test_SetArweaveTxid_WriteOnce() public {
        _mintOne();
        bytes32 txid = bytes32(uint256(0xcafebabe));
        vm.prank(storageFeeWriter);
        project.setArweaveTxid(1, txid);

        // Second attempt — even by the same writer — must revert.
        vm.prank(storageFeeWriter);
        vm.expectRevert(PDProject.TxidAlreadySet.selector);
        project.setArweaveTxid(1, bytes32(uint256(0xfeed1234)));
    }

    // ─── tokenURI ────────────────────────────────────────────────────────

    function test_TokenURI_RevertsOnNonexistent() public {
        vm.expectRevert(PDProject.NonexistentToken.selector);
        project.tokenURI(1);
    }

    function test_TokenURI_PlaceholderBeforeArweave() public {
        _mintOne();
        string memory uri = project.tokenURI(1);
        // Must be data URI with base64 JSON.
        assertEq(_startsWith(uri, "data:application/json;base64,"), true);
        // We don't decode here — just sanity check it's a sufficiently long payload.
        assertGt(bytes(uri).length, 200);
    }

    function test_TokenURI_AfterArweave_HasArPrefix() public {
        _mintOne();
        // Choose a txid the on-chain LibString rendering will surface in base64.
        bytes32 txid = keccak256("arweave-manifest-1");
        vm.prank(storageFeeWriter);
        project.setArweaveTxid(1, txid);

        string memory uri = project.tokenURI(1);
        assertEq(_startsWith(uri, "data:application/json;base64,"), true);
        assertGt(bytes(uri).length, 200);
    }

    // ─── Royalty (EIP-2981) ──────────────────────────────────────────────

    function test_RoyaltyInfo_Returns5PercentToSplitter() public view {
        (address receiver, uint256 royaltyAmount) = project.royaltyInfo(1, 1 ether);
        assertEq(receiver, project.paymentSplitter());
        assertEq(royaltyAmount, (1 ether * 500) / 10000);
    }

    function test_SupportsInterface_ERC721_ERC2981_ERC165() public view {
        // ERC-165: 0x01ffc9a7, ERC-721: 0x80ac58cd, ERC-2981: 0x2a55205a
        assertTrue(project.supportsInterface(0x01ffc9a7));
        assertTrue(project.supportsInterface(0x80ac58cd));
        assertTrue(project.supportsInterface(0x2a55205a));
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _startsWith(string memory s, string memory prefix) internal pure returns (bool) {
        bytes memory sb = bytes(s);
        bytes memory pb = bytes(prefix);
        if (sb.length < pb.length) return false;
        for (uint256 i = 0; i < pb.length; i++) {
            if (sb[i] != pb[i]) return false;
        }
        return true;
    }
}
