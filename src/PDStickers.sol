// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @title PDStickers
/// @notice Brendon's sticker shop. ERC-1155 collectible SVGs stored fully on-chain.
///
///         SHEETS ONLY — no individual sticker purchases on primary.
///         Collectors buy Sticker Sheets (bundles) and receive individual ERC-1155
///         tokens via _mintBatch(). Individual stickers are tradeable on OpenSea.
///
///         On-chain metadata: uri() returns a base64-encoded JSON with the SVG
///         embedded as a data URI. Zero external dependencies. Fully permanent.
///
///         Immutable logic. Admin transferable for multisig migration.
contract PDStickers is ERC1155, IERC2981 {
    using LibString for uint256;

    // ─── Constants ───────────────────────────────────────────────────────

    /// @notice Secondary royalty in basis points (500 = 5%).
    uint256 private constant ROYALTY_BPS = 500;

    /// @notice Hard cap on stickers per sheet — protects buyers from a malformed
    ///         sheet definition that would be unaffordable or exceed block gas.
    ///         Discord Emoji Pack is ~43; 64 leaves generous headroom for future packs.
    uint256 public constant MAX_STICKERS_PER_SHEET = 64;

    // ─── Types ───────────────────────────────────────────────────────────

    struct Sticker {
        string name;
        uint256 maxSupply;      // 0 = open edition (unlimited)
        uint256 minted;         // incremented by sheet purchases
        address svgPointer;     // SSTORE2 address for on-chain SVG
        bool active;
    }

    struct Sheet {
        string name;            // e.g. "Discord Emoji Pack"
        uint256[] stickerIds;   // which stickers are in this sheet
        uint256 priceWei;       // sheet price in ETH
        uint256 maxSheets;      // 0 = unlimited
        uint256 sold;
        bool active;
    }

    // ─── State ───────────────────────────────────────────────────────────

    address public admin;

    mapping(uint256 => Sticker) public stickers;
    uint256 public nextStickerId = 1;

    mapping(uint256 => Sheet) internal _sheets;
    uint256 public nextSheetId = 1;

    // ─── Errors ──────────────────────────────────────────────────────────

    error NotAdmin();
    error ZeroAddress();
    error StickerDoesNotExist();
    error StickerNotActive();
    error StickerMaxSupplyReached(uint256 stickerId);
    error SheetDoesNotExist();
    error SheetNotActive();
    error SheetSoldOut();
    error IncorrectPayment();
    error EmptyStickerList();
    error TooManyStickers();
    error DuplicateStickerId(uint256 stickerId);
    error NothingToWithdraw();
    error TransferFailed();

    // ─── Events ──────────────────────────────────────────────────────────

    event StickerCreated(uint256 indexed stickerId, string name, uint256 maxSupply);
    event SheetCreated(
        uint256 indexed sheetId,
        string name,
        uint256[] stickerIds,
        uint256 priceWei,
        uint256 maxSheets
    );
    event SheetPurchased(address indexed buyer, uint256 indexed sheetId, uint256 stickerCount);
    event StickerDeactivated(uint256 indexed stickerId);
    event SheetDeactivated(uint256 indexed sheetId);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(address _admin) ERC1155("") {
        if (_admin == address(0)) revert ZeroAddress();
        admin = _admin;
    }

    // ─── Sticker Management ──────────────────────────────────────────────

    function createSticker(
        string calldata name,
        uint256 maxSupply,
        bytes calldata svgData
    ) external onlyAdmin returns (uint256 stickerId) {
        stickerId = nextStickerId++;
        address pointer = SSTORE2.write(svgData);

        stickers[stickerId] = Sticker({
            name: name,
            maxSupply: maxSupply,
            minted: 0,
            svgPointer: pointer,
            active: true
        });

        emit StickerCreated(stickerId, name, maxSupply);
    }

    function deactivateSticker(uint256 stickerId) external onlyAdmin {
        if (stickers[stickerId].svgPointer == address(0)) revert StickerDoesNotExist();
        stickers[stickerId].active = false;
        emit StickerDeactivated(stickerId);
    }

    // ─── Sheet Management ────────────────────────────────────────────────

    /// @notice Create a Sticker Sheet.
    ///         Validates: non-empty, within size cap, every id exists + is active,
    ///         and no duplicate ids (so buyers always get distinct stickers per sheet).
    function createSheet(
        string calldata name,
        uint256[] calldata stickerIds,
        uint256 priceWei,
        uint256 maxSheets
    ) external onlyAdmin returns (uint256 sheetId) {
        uint256 len = stickerIds.length;
        if (len == 0) revert EmptyStickerList();
        if (len > MAX_STICKERS_PER_SHEET) revert TooManyStickers();

        // Validate existence + activity + no duplicates.
        // O(n^2) on `len`, which is bounded above by MAX_STICKERS_PER_SHEET (64).
        // Worth it to avoid the storage/memory overhead of a seen-map.
        for (uint256 i; i < len;) {
            uint256 sid = stickerIds[i];
            Sticker storage s = stickers[sid];
            if (s.svgPointer == address(0)) revert StickerDoesNotExist();
            if (!s.active) revert StickerNotActive();

            for (uint256 j = i + 1; j < len;) {
                if (stickerIds[j] == sid) revert DuplicateStickerId(sid);
                unchecked { ++j; }
            }

            unchecked { ++i; }
        }

        sheetId = nextSheetId++;

        _sheets[sheetId].name = name;
        _sheets[sheetId].stickerIds = stickerIds;
        _sheets[sheetId].priceWei = priceWei;
        _sheets[sheetId].maxSheets = maxSheets;
        _sheets[sheetId].active = true;

        emit SheetCreated(sheetId, name, stickerIds, priceWei, maxSheets);
    }

    function deactivateSheet(uint256 sheetId) external onlyAdmin {
        if (_sheets[sheetId].stickerIds.length == 0) revert SheetDoesNotExist();
        _sheets[sheetId].active = false;
        emit SheetDeactivated(sheetId);
    }

    // ─── Purchase ────────────────────────────────────────────────────────

    /// @notice The ONLY primary purchase function. Sends exact ETH, receives all
    ///         stickers in the sheet via _mintBatch(). Each sticker lands as an
    ///         independent ERC-1155 token tradeable on OpenSea.
    function purchaseSheet(uint256 sheetId) external payable {
        Sheet storage sheet = _sheets[sheetId];
        if (sheet.stickerIds.length == 0) revert SheetDoesNotExist();
        if (!sheet.active) revert SheetNotActive();
        if (sheet.maxSheets > 0 && sheet.sold >= sheet.maxSheets) revert SheetSoldOut();
        if (msg.value != sheet.priceWei) revert IncorrectPayment();

        uint256 len = sheet.stickerIds.length;
        uint256[] memory ids = new uint256[](len);
        uint256[] memory amounts = new uint256[](len);

        for (uint256 i; i < len;) {
            uint256 sid = sheet.stickerIds[i];
            Sticker storage s = stickers[sid];

            if (!s.active) revert StickerNotActive();
            if (s.maxSupply > 0 && s.minted >= s.maxSupply)
                revert StickerMaxSupplyReached(sid);

            unchecked { ++s.minted; }
            ids[i] = sid;
            amounts[i] = 1;
            unchecked { ++i; }
        }

        unchecked { ++sheet.sold; }

        _mintBatch(msg.sender, ids, amounts, "");

        emit SheetPurchased(msg.sender, sheetId, len);
    }

    // ─── On-Chain Metadata ───────────────────────────────────────────────

    function uri(uint256 id) public view override returns (string memory) {
        Sticker storage s = stickers[id];
        if (s.svgPointer == address(0)) revert StickerDoesNotExist();

        bytes memory svgBytes = SSTORE2.read(s.svgPointer);
        string memory svgBase64 = Base64.encode(svgBytes);

        string memory json = string.concat(
            '{"name":"',
            s.name,
            '","description":"Price Discussion Sticker","image":"data:image/svg+xml;base64,',
            svgBase64,
            '","properties":{"collection":"Price Discussion","type":"sticker"}}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    // ─── EIP-2981 Royalties ──────────────────────────────────────────────

    /// @notice 5% royalty on secondary sales, all to admin (Brendon).
    function royaltyInfo(
        uint256, /* tokenId — same config for all stickers */
        uint256 salePrice
    ) external view override returns (address receiver, uint256 royaltyAmount) {
        receiver = admin;
        royaltyAmount = (salePrice * ROYALTY_BPS) / 10_000;
    }

    // ─── Withdrawal ──────────────────────────────────────────────────────

    function withdraw() external onlyAdmin {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NothingToWithdraw();
        (bool success,) = admin.call{value: balance}("");
        if (!success) revert TransferFailed();
    }

    // ─── Admin Management ────────────────────────────────────────────────

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // ─── View Functions ──────────────────────────────────────────────────

    function getSheetStickerIds(uint256 sheetId) external view returns (uint256[] memory) {
        if (_sheets[sheetId].stickerIds.length == 0) revert SheetDoesNotExist();
        return _sheets[sheetId].stickerIds;
    }

    function sheets(uint256 sheetId)
        external
        view
        returns (
            string memory name,
            uint256[] memory stickerIds,
            uint256 priceWei,
            uint256 maxSheets,
            uint256 sold,
            bool active
        )
    {
        Sheet storage s = _sheets[sheetId];
        return (s.name, s.stickerIds, s.priceWei, s.maxSheets, s.sold, s.active);
    }

    function getStickerSVG(uint256 stickerId) external view returns (string memory) {
        Sticker storage s = stickers[stickerId];
        if (s.svgPointer == address(0)) revert StickerDoesNotExist();
        return string(SSTORE2.read(s.svgPointer));
    }

    /// @notice Cheap pre-flight for the frontend — validates sheet + every contained sticker.
    function canPurchaseSheet(uint256 sheetId) external view returns (bool) {
        Sheet storage sheet = _sheets[sheetId];
        if (sheet.stickerIds.length == 0 || !sheet.active) return false;
        if (sheet.maxSheets > 0 && sheet.sold >= sheet.maxSheets) return false;

        uint256 len = sheet.stickerIds.length;
        for (uint256 i; i < len;) {
            Sticker storage s = stickers[sheet.stickerIds[i]];
            if (!s.active) return false;
            if (s.maxSupply > 0 && s.minted >= s.maxSupply) return false;
            unchecked { ++i; }
        }
        return true;
    }

    // ─── ERC-165 ─────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
