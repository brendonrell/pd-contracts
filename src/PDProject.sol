// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";

/// @dev Minimal interface used by PDProject to read the mutable baseTokenURI
///      from PDFactory. MUST be declared outside PDProject — Solidity does
///      not allow interfaces inside contract bodies. (This was the blocker in
///      the 4.6 draft.)
interface IPDFactory {
    function baseTokenURI() external view returns (string memory);
}

/// @title PDProject
/// @notice A single generative art Project on Price Discussion.
///         Deployed by PDFactory. Vanilla ERC-721 with on-chain script storage,
///         deterministic token hashes, and EIP-2981 royalties via PaymentSplitter.
///         Immutable. No admin functions. No pause. Set it and forget it.
contract PDProject is ERC721, IERC2981 {
    using Strings for uint256;
    using Strings for address;

    // ─── State ───────────────────────────────────────────────────────────

    address public immutable artist;
    address public immutable factory;
    address public immutable paymentSplitter;
    uint256 public immutable mintPrice;
    uint256 public immutable maxSupply;

    /// @notice SSTORE2 pointers to on-chain script chunks, in order.
    address[] internal _scriptPointers;

    /// @notice Total tokens minted. Also the id of the most recently minted token.
    ///         Token ids start at 1 and are strictly increasing.
    uint256 public totalMinted;

    /// @notice Deterministic hash per token — the seed for generative output.
    mapping(uint256 => bytes32) public tokenHashes;

    uint256 private constant PLATFORM_FEE_BPS = 500; // 5% primary fee
    uint256 private constant ROYALTY_BPS = 500;      // 5% total secondary royalty (split 3/2 by splitter)

    /// @notice Accumulated platform fees available for factory withdrawal.
    uint256 public accumulatedFees;

    // ─── Errors ──────────────────────────────────────────────────────────

    error NotFactory();
    error IncorrectPayment();
    error MaxSupplyReached();
    error TransferFailed();
    error QuantityZero();

    // ─── Events ──────────────────────────────────────────────────────────

    event Minted(address indexed minter, uint256 indexed tokenId, bytes32 tokenHash);
    event PlatformFeesWithdrawn(address indexed to, uint256 amount);

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(
        string memory _name,
        string memory _symbol,
        address _artist,
        uint256 _mintPrice,
        uint256 _maxSupply,
        address _splitter,
        bytes[] memory _scriptChunks
    ) ERC721(_name, _symbol) {
        artist = _artist;
        factory = msg.sender;
        paymentSplitter = _splitter;
        mintPrice = _mintPrice;
        maxSupply = _maxSupply;

        uint256 len = _scriptChunks.length;
        for (uint256 i; i < len;) {
            _scriptPointers.push(SSTORE2.write(_scriptChunks[i]));
            unchecked { ++i; }
        }
    }

    // ─── Minting ─────────────────────────────────────────────────────────

    /// @notice Mint `quantity` tokens. Strict exact payment.
    ///         95% goes to artist (direct, last step), 5% accrues for platform sweep.
    ///         Follows Checks-Effects-Interactions: all state mutations complete
    ///         before the only untrusted external call (artist payout).
    function mint(uint256 quantity) external payable {
        // ── Checks ──
        if (quantity == 0) revert QuantityZero();
        if (msg.value != mintPrice * quantity) revert IncorrectPayment();
        if (totalMinted + quantity > maxSupply) revert MaxSupplyReached();

        // ── Effects: split payment ──
        uint256 platformFee = (msg.value * PLATFORM_FEE_BPS) / 10_000;
        uint256 artistProceeds = msg.value - platformFee;
        accumulatedFees += platformFee;

        // ── Effects: mint tokens + generate hashes ──
        // Cache blockhash once — same for every token in a batch (matches Art Blocks).
        // Include msg.sender in the entropy so same-block batch mints don't
        // produce hashes correlated only by tokenId.
        bytes32 blockHash = blockhash(block.number - 1);
        address minter = msg.sender;
        for (uint256 i; i < quantity;) {
            uint256 tokenId;
            unchecked { tokenId = ++totalMinted; } // bounded above by maxSupply check
            bytes32 hash = keccak256(abi.encodePacked(tokenId, blockHash, minter));
            tokenHashes[tokenId] = hash;
            _mint(minter, tokenId);
            emit Minted(minter, tokenId, hash);
            unchecked { ++i; }
        }

        // ── Interactions: pay artist last ──
        (bool success,) = artist.call{value: artistProceeds}("");
        if (!success) revert TransferFailed();
    }

    // ─── Platform Fee Withdrawal ─────────────────────────────────────────

    /// @notice Factory-only sweep of accumulated platform fees.
    ///         No-op when there is nothing to withdraw (admin UX — lets the
    ///         factory sweep an already-swept Project without reverting).
    function withdraw() external {
        if (msg.sender != factory) revert NotFactory();
        uint256 amount = accumulatedFees;
        if (amount == 0) return; // silent no-op — intentional
        accumulatedFees = 0;
        emit PlatformFeesWithdrawn(msg.sender, amount);
        (bool success,) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    // ─── Script Reading ──────────────────────────────────────────────────

    function scriptChunkCount() external view returns (uint256) {
        return _scriptPointers.length;
    }

    function scriptPointers(uint256 index) external view returns (address) {
        return _scriptPointers[index];
    }

    function scriptChunk(uint256 index) external view returns (string memory) {
        return string(SSTORE2.read(_scriptPointers[index]));
    }

    /// @notice Concatenate every script chunk. Gas-heavy — for off-chain reads only.
    function getScript() external view returns (string memory script) {
        uint256 len = _scriptPointers.length;
        for (uint256 i; i < len;) {
            script = string.concat(script, string(SSTORE2.read(_scriptPointers[i])));
            unchecked { ++i; }
        }
    }

    // ─── Metadata ────────────────────────────────────────────────────────

    /// @notice Token metadata URI. Delegates to factory's baseTokenURI so the
    ///         Project stays immutable while the metadata endpoint can migrate.
    ///         Format: {baseTokenURI}{projectAddress}/{tokenId}
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory base = IPDFactory(factory).baseTokenURI();
        return string.concat(
            base,
            Strings.toHexString(address(this)),
            "/",
            tokenId.toString()
        );
    }

    /// @notice Project-level metadata for OpenSea.
    ///         Format: {baseTokenURI}{projectAddress}
    function contractURI() external view returns (string memory) {
        string memory base = IPDFactory(factory).baseTokenURI();
        return string.concat(base, Strings.toHexString(address(this)));
    }

    // ─── EIP-2981 Royalties ──────────────────────────────────────────────

    function royaltyInfo(
        uint256, /* tokenId — same config for all tokens */
        uint256 salePrice
    ) external view override returns (address receiver, uint256 royaltyAmount) {
        receiver = paymentSplitter;
        royaltyAmount = (salePrice * ROYALTY_BPS) / 10_000;
    }

    // ─── ERC-165 ─────────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC2981).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
