// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PDStickers} from "../src/PDStickers.sol";

contract PDStickersTest is Test {
    PDStickers stickers;
    address admin = makeAddr("admin");
    address buyer = makeAddr("buyer");
    address random = makeAddr("random");

    function setUp() public {
        stickers = new PDStickers(admin);
        vm.deal(buyer, 10 ether);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _createSticker(string memory name, uint256 maxSupply) internal returns (uint256) {
        vm.prank(admin);
        return stickers.createSticker(name, maxSupply, bytes("<svg></svg>"));
    }

    function _idArray(uint256[] memory arr) internal pure returns (uint256[] memory) {
        return arr;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    function test_Constructor_SetsAdmin() public view {
        assertEq(stickers.admin(), admin);
    }

    function test_Constructor_RevertsOnZero() public {
        vm.expectRevert(PDStickers.ZeroAddress.selector);
        new PDStickers(address(0));
    }

    // ─── Stickers ────────────────────────────────────────────────────────

    function test_CreateSticker_OnlyAdmin() public {
        vm.prank(random);
        vm.expectRevert(PDStickers.NotAdmin.selector);
        stickers.createSticker("X", 0, bytes("<svg/>"));
    }

    function test_CreateSticker_Success() public {
        uint256 id = _createSticker("LOVEU", 100);
        assertEq(id, 1);

        (, uint256 maxSupply, uint256 minted, address ptr, bool active) = stickers.stickers(id);
        assertEq(maxSupply, 100);
        assertEq(minted, 0);
        assertTrue(ptr != address(0));
        assertTrue(active);
    }

    function test_CreateSticker_AssignsSequentialIds() public {
        uint256 a = _createSticker("A", 0);
        uint256 b = _createSticker("B", 0);
        uint256 c = _createSticker("C", 0);
        assertEq(a, 1);
        assertEq(b, 2);
        assertEq(c, 3);
    }

    // ─── Sheet Creation: Fixes ───────────────────────────────────────────

    function test_CreateSheet_RevertsOnEmpty() public {
        uint256[] memory empty = new uint256[](0);
        vm.prank(admin);
        vm.expectRevert(PDStickers.EmptyStickerList.selector);
        stickers.createSheet("Empty", empty, 0.01 ether, 0);
    }

    function test_CreateSheet_RevertsOnTooManyStickers() public {
        // Fix verified: MAX_STICKERS_PER_SHEET = 64
        // Build 65 stickers and try to put them all in one sheet
        uint256[] memory ids = new uint256[](65);
        for (uint256 i = 0; i < 65; i++) {
            ids[i] = _createSticker("x", 0);
        }

        vm.prank(admin);
        vm.expectRevert(PDStickers.TooManyStickers.selector);
        stickers.createSheet("Huge", ids, 0.01 ether, 0);
    }

    function test_CreateSheet_RevertsOnDuplicateStickerId() public {
        // Fix verified: duplicates rejected
        uint256 a = _createSticker("A", 0);
        uint256 b = _createSticker("B", 0);

        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = a; // duplicate of index 0

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PDStickers.DuplicateStickerId.selector, a));
        stickers.createSheet("Dupe", ids, 0.01 ether, 0);
    }

    function test_CreateSheet_RevertsOnNonexistentSticker() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;

        vm.prank(admin);
        vm.expectRevert(PDStickers.StickerDoesNotExist.selector);
        stickers.createSheet("Ghost", ids, 0.01 ether, 0);
    }

    function test_CreateSheet_RevertsOnInactiveSticker() public {
        uint256 a = _createSticker("A", 0);
        vm.prank(admin);
        stickers.deactivateSticker(a);

        uint256[] memory ids = new uint256[](1);
        ids[0] = a;

        vm.prank(admin);
        vm.expectRevert(PDStickers.StickerNotActive.selector);
        stickers.createSheet("Inactive", ids, 0.01 ether, 0);
    }

    function test_CreateSheet_SuccessWithExactlyCapStickers() public {
        // Cap is inclusive — 64 stickers in one sheet must succeed
        uint256[] memory ids = new uint256[](64);
        for (uint256 i = 0; i < 64; i++) {
            ids[i] = _createSticker("x", 0);
        }

        vm.prank(admin);
        uint256 sheetId = stickers.createSheet("Full", ids, 0.01 ether, 0);
        assertEq(sheetId, 1);
    }

    // ─── Purchase Sheet ──────────────────────────────────────────────────

    function test_PurchaseSheet_DeliversAllStickers() public {
        uint256 a = _createSticker("A", 0);
        uint256 b = _createSticker("B", 0);
        uint256 c = _createSticker("C", 0);

        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;

        vm.prank(admin);
        uint256 sheetId = stickers.createSheet("Pack", ids, 0.01 ether, 0);

        vm.prank(buyer);
        stickers.purchaseSheet{value: 0.01 ether}(sheetId);

        assertEq(stickers.balanceOf(buyer, a), 1);
        assertEq(stickers.balanceOf(buyer, b), 1);
        assertEq(stickers.balanceOf(buyer, c), 1);
    }

    function test_PurchaseSheet_RevertsOnWrongPayment() public {
        uint256 a = _createSticker("A", 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;

        vm.prank(admin);
        uint256 sheetId = stickers.createSheet("Pack", ids, 0.01 ether, 0);

        vm.prank(buyer);
        vm.expectRevert(PDStickers.IncorrectPayment.selector);
        stickers.purchaseSheet{value: 0.009 ether}(sheetId);
    }

    function test_PurchaseSheet_RespectsSheetCap() public {
        uint256 a = _createSticker("A", 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;

        vm.prank(admin);
        uint256 sheetId = stickers.createSheet("Limited", ids, 0.01 ether, 2); // maxSheets = 2

        vm.prank(buyer);
        stickers.purchaseSheet{value: 0.01 ether}(sheetId);
        vm.prank(buyer);
        stickers.purchaseSheet{value: 0.01 ether}(sheetId);

        vm.prank(buyer);
        vm.expectRevert(PDStickers.SheetSoldOut.selector);
        stickers.purchaseSheet{value: 0.01 ether}(sheetId);
    }

    function test_PurchaseSheet_RevertsWhenStickerMaxSupplyHit() public {
        uint256 limited = _createSticker("Limited", 2); // only 2 ever
        uint256 open = _createSticker("Open", 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = limited;
        ids[1] = open;

        vm.prank(admin);
        uint256 sheetId = stickers.createSheet("Mixed", ids, 0.01 ether, 0);

        vm.prank(buyer);
        stickers.purchaseSheet{value: 0.01 ether}(sheetId);
        vm.prank(buyer);
        stickers.purchaseSheet{value: 0.01 ether}(sheetId);

        // Third purchase fails because `limited` hit maxSupply
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(PDStickers.StickerMaxSupplyReached.selector, limited)
        );
        stickers.purchaseSheet{value: 0.01 ether}(sheetId);
    }

    function test_PurchaseSheet_DeactivatedSheetBlocks() public {
        uint256 a = _createSticker("A", 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;

        vm.prank(admin);
        uint256 sheetId = stickers.createSheet("Pack", ids, 0.01 ether, 0);

        vm.prank(admin);
        stickers.deactivateSheet(sheetId);

        vm.prank(buyer);
        vm.expectRevert(PDStickers.SheetNotActive.selector);
        stickers.purchaseSheet{value: 0.01 ether}(sheetId);
    }

    function test_CanPurchaseSheet_AllConditions() public {
        uint256 a = _createSticker("A", 1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;

        vm.prank(admin);
        uint256 sheetId = stickers.createSheet("Pack", ids, 0.01 ether, 0);

        assertTrue(stickers.canPurchaseSheet(sheetId));

        // Purchase depletes sticker supply
        vm.prank(buyer);
        stickers.purchaseSheet{value: 0.01 ether}(sheetId);
        assertFalse(stickers.canPurchaseSheet(sheetId)); // sticker now depleted
    }

    // ─── Royalty ─────────────────────────────────────────────────────────

    function test_RoyaltyInfo_FivePercentToAdmin() public view {
        (address receiver, uint256 amount) = stickers.royaltyInfo(1, 1 ether);
        assertEq(receiver, admin);
        assertEq(amount, 0.05 ether);
    }

    // ─── Withdrawal ──────────────────────────────────────────────────────

    function test_Withdraw_SendsToAdmin() public {
        uint256 a = _createSticker("A", 0);
        uint256[] memory ids = new uint256[](1);
        ids[0] = a;

        vm.prank(admin);
        uint256 sheetId = stickers.createSheet("Pack", ids, 0.01 ether, 0);

        vm.prank(buyer);
        stickers.purchaseSheet{value: 0.01 ether}(sheetId);

        uint256 before_ = admin.balance;
        vm.prank(admin);
        stickers.withdraw();
        assertEq(admin.balance, before_ + 0.01 ether);
    }

    function test_Withdraw_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(PDStickers.NothingToWithdraw.selector);
        stickers.withdraw();
    }
}
