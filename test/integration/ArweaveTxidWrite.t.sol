// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PDFactory} from "../../src/PDFactory.sol";
import {PDProject} from "../../src/PDProject.sol";
import {
    MockChainlinkAggregator,
    MockUniswapV3Pool,
    MockWETH,
    MockUSDC
} from "../mocks/Mocks.sol";

/// @dev Covers the writer permissioning and write-once enforcement on
///      setArweaveTxid, including admin rotation of the writer key.
contract ArweaveTxidWriteTest is Test {
    PDFactory factory;
    PDProject project;

    address admin = makeAddr("admin");
    address platformWallet = makeAddr("platformWallet");
    address storageFeeWallet = makeAddr("storageFeeWallet");
    address writer1 = makeAddr("writer1");
    address writer2 = makeAddr("writer2");
    address artist = makeAddr("artist");
    address minter = makeAddr("minter");
    address rando = makeAddr("rando");

    function setUp() public {
        vm.warp(1_700_000_000);

        address chainlink = address(new MockChainlinkAggregator(int256(3000e8), block.timestamp));
        address pool = address(new MockUniswapV3Pool(int24(-196250)));
        address weth = address(new MockWETH());
        address usdc = address(new MockUSDC());

        factory = new PDFactory(
            admin,
            platformWallet,
            storageFeeWallet,
            writer1,
            chainlink,
            pool,
            weth,
            usdc
        );

        vm.prank(admin);
        factory.whitelistArtist(artist);

        bytes[] memory chunks = new bytes[](1);
        chunks[0] = bytes("x");

        vm.prank(artist);
        address proj = factory.createProject("A", "A", 100, 0.01 ether, chunks, "");
        project = PDProject(proj);

        // Mint a handful so we have multiple token IDs to test against.
        vm.deal(minter, 10 ether);
        uint256 required = (0.01 ether + project.currentStorageFeeWei()) * 3;
        vm.prank(minter);
        project.mint{value: required}(3);
    }

    function test_OnlyCurrentWriter_CanSetTxid() public {
        bytes32 txid = bytes32(uint256(0xdead));

        vm.prank(rando);
        vm.expectRevert(PDProject.NotWriter.selector);
        project.setArweaveTxid(1, txid);

        vm.prank(artist);
        vm.expectRevert(PDProject.NotWriter.selector);
        project.setArweaveTxid(1, txid);

        vm.prank(admin); // admin has no metadata reach
        vm.expectRevert(PDProject.NotWriter.selector);
        project.setArweaveTxid(1, txid);

        // writer1 succeeds.
        vm.prank(writer1);
        project.setArweaveTxid(1, txid);
        assertEq(project.tokenArweaveManifests(1), txid);
    }

    function test_WriteOnce_BlocksSameWriter() public {
        bytes32 first = bytes32(uint256(0x1111));
        bytes32 second = bytes32(uint256(0x2222));

        vm.prank(writer1);
        project.setArweaveTxid(1, first);

        vm.prank(writer1);
        vm.expectRevert(PDProject.TxidAlreadySet.selector);
        project.setArweaveTxid(1, second);

        assertEq(project.tokenArweaveManifests(1), first);
    }

    function test_WriterRotation_PreviousWriterLosesAccess() public {
        // Admin rotates the writer key.
        vm.prank(admin);
        factory.setStorageFeeWriter(writer2);

        // writer1 can no longer write — even to a token it has never touched.
        vm.prank(writer1);
        vm.expectRevert(PDProject.NotWriter.selector);
        project.setArweaveTxid(2, bytes32(uint256(0xaaaa)));

        // writer2 now has authority.
        vm.prank(writer2);
        project.setArweaveTxid(2, bytes32(uint256(0xbbbb)));
        assertEq(project.tokenArweaveManifests(2), bytes32(uint256(0xbbbb)));
    }

    function test_WriteOnce_PersistsAcrossRotation() public {
        bytes32 first = bytes32(uint256(0x1111));

        vm.prank(writer1);
        project.setArweaveTxid(1, first);

        vm.prank(admin);
        factory.setStorageFeeWriter(writer2);

        // Even the new writer can't overwrite.
        vm.prank(writer2);
        vm.expectRevert(PDProject.TxidAlreadySet.selector);
        project.setArweaveTxid(1, bytes32(uint256(0x9999)));

        assertEq(project.tokenArweaveManifests(1), first);
    }

    function test_NonexistentToken_Reverts() public {
        vm.prank(writer1);
        vm.expectRevert(PDProject.NonexistentToken.selector);
        project.setArweaveTxid(999, bytes32(uint256(0xdead)));
    }

    function test_ZeroTxid_Reverts() public {
        vm.prank(writer1);
        vm.expectRevert(PDProject.ZeroTxid.selector);
        project.setArweaveTxid(1, bytes32(0));
    }

    function test_Event_ArweaveTxidSet() public {
        bytes32 txid = bytes32(uint256(0xc0ffee));
        vm.expectEmit(true, false, false, true, address(project));
        emit PDProject.ArweaveTxidSet(2, txid);

        vm.prank(writer1);
        project.setArweaveTxid(2, txid);
    }
}
