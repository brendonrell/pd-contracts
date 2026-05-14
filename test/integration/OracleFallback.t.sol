// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PDFactory} from "../../src/PDFactory.sol";
import {PDProject} from "../../src/PDProject.sol";
import {OracleLibrary} from "../../src/libraries/UniswapV3OracleLibrary.sol";
import {
    MockChainlinkAggregator,
    MockUniswapV3Pool,
    MockWETH,
    MockUSDC
} from "../mocks/Mocks.sol";

/// @dev Exercises the full price feed cascade:
///        1. Chainlink fresh → used.
///        2. Chainlink stale → retry → Uniswap TWAP.
///        3. Chainlink zero answer → Uniswap.
///        4. Chainlink reverts → Uniswap.
///        5. Both fail → mint reverts OracleFailed.
///
/// The setup deliberately picks a Uniswap tick that yields a quote
/// *different* from the Chainlink answer so the test can prove which
/// branch handled the read by comparing the resulting storage fee.
contract OracleFallbackTest is Test {
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

    address weth;
    address usdc;

    int24 constant TWAP_TICK = int24(-210000); // distinct from a ~3000 USD/ETH Chainlink read

    uint256 constant MINT_PRICE = 0.01 ether;

    function setUp() public {
        vm.warp(1_700_000_000);

        chainlinkMock = new MockChainlinkAggregator(int256(3000e8), block.timestamp);
        poolMock = new MockUniswapV3Pool(TWAP_TICK);
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
        chunks[0] = bytes("draw(){}");

        vm.prank(artist);
        address proj = factory.createProject("O", "O", 100, MINT_PRICE, chunks, "");
        project = PDProject(proj);

        vm.deal(minter, 100 ether);
    }

    // ─── Expected fees per oracle path ───────────────────────────────────

    function _expectedChainlinkFee(int256 answer) internal pure returns (uint256) {
        // ethUsd18 = uint256(answer) * 1e10
        uint256 ethUsd18 = uint256(answer) * 1e10;
        return (2 * 1e36) / ethUsd18;
    }

    function _expectedUniswapFee() internal view returns (uint256) {
        uint256 usdcPer1Eth = OracleLibrary.getQuoteAtTick(TWAP_TICK, 1e18, weth, usdc);
        if (usdcPer1Eth == 0) return 0;
        uint256 ethUsd18 = usdcPer1Eth * 1e12;
        return (2 * 1e36) / ethUsd18;
    }

    function test_Setup_ChainlinkAndUniswapFeesDiffer() public view {
        // Sanity: if these were equal the cascade test could pass spuriously.
        uint256 c = _expectedChainlinkFee(int256(3000e8));
        uint256 u = _expectedUniswapFee();
        assertTrue(u > 0, "uniswap quote must be non-zero");
        assertTrue(c != u, "fees must differ to distinguish oracle paths");
    }

    // ─── 1. Chainlink fresh → used ───────────────────────────────────────

    function test_Cascade_UsesChainlinkWhenFresh() public {
        uint256 expected = _expectedChainlinkFee(int256(3000e8));
        assertEq(project.currentStorageFeeWei(), expected);

        // Mint should accept exactly the Chainlink-derived fee.
        uint256 required = MINT_PRICE + expected;
        vm.prank(minter);
        project.mint{value: required}(1);
        assertEq(project.totalMinted(), 1);
    }

    // ─── 2. Chainlink stale → Uniswap ────────────────────────────────────

    function test_Cascade_FallsBackToUniswap_WhenChainlinkStale() public {
        // Push updatedAt outside the 1h staleness window.
        chainlinkMock.setUpdatedAt(block.timestamp - 1 hours - 1);

        uint256 expected = _expectedUniswapFee();
        assertEq(project.currentStorageFeeWei(), expected);

        uint256 required = MINT_PRICE + expected;
        vm.prank(minter);
        project.mint{value: required}(1);
        assertEq(project.totalMinted(), 1);
    }

    // ─── 3. Chainlink zero answer → Uniswap ──────────────────────────────

    function test_Cascade_FallsBackToUniswap_WhenChainlinkZeroAnswer() public {
        chainlinkMock.setAnswer(0);

        uint256 expected = _expectedUniswapFee();
        assertEq(project.currentStorageFeeWei(), expected);

        uint256 required = MINT_PRICE + expected;
        vm.prank(minter);
        project.mint{value: required}(1);
        assertEq(project.totalMinted(), 1);
    }

    // ─── 4. Chainlink reverts → Uniswap ──────────────────────────────────

    function test_Cascade_FallsBackToUniswap_WhenChainlinkReverts() public {
        chainlinkMock.setShouldRevert(true);

        uint256 expected = _expectedUniswapFee();
        assertEq(project.currentStorageFeeWei(), expected);

        uint256 required = MINT_PRICE + expected;
        vm.prank(minter);
        project.mint{value: required}(1);
        assertEq(project.totalMinted(), 1);
    }

    // ─── 5. Both fail → revert OracleFailed ──────────────────────────────

    function test_Cascade_RevertsWhenBothOraclesFail() public {
        chainlinkMock.setShouldRevert(true);
        poolMock.setShouldRevert(true);

        // View also reverts (calls into the cascade).
        vm.expectRevert(PDProject.OracleFailed.selector);
        project.currentStorageFeeWei();

        // Mint reverts with the same reason.
        vm.prank(minter);
        vm.expectRevert(PDProject.OracleFailed.selector);
        project.mint{value: 1 ether}(1);
    }

    // ─── Updated Chainlink answer propagates ─────────────────────────────

    function test_Cascade_UpdatedChainlinkAnswer_PropagatesToFee() public {
        // Switch to $4000 — fee should drop proportionally.
        chainlinkMock.setAnswer(int256(4000e8));
        uint256 expected = _expectedChainlinkFee(int256(4000e8));
        assertEq(project.currentStorageFeeWei(), expected);
    }
}
