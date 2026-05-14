// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol";
import {OracleLibrary} from "./libraries/UniswapV3OracleLibrary.sol";

/// @dev Minimal interface used by PDProject to read mutable factory state
///      (wallets + writer). Chainlink feed, Uniswap V3 pool, and the WETH/USDC
///      token addresses are factory-immutable — locked at deploy time.
interface IPDFactory {
    function platformWallet() external view returns (address);
    function storageFeeWallet() external view returns (address);
    function storageFeeWriter() external view returns (address);
    function chainlinkFeed() external view returns (address);
    function uniswapV3Pool() external view returns (address);
    function weth() external view returns (address);
    function usdc() external view returns (address);
}

/// @title PDProject
/// @notice A single generative art Project on Price Discussion.
///         Deployed by PDFactory. Vanilla ERC-721. Holds the script on-chain
///         via SSTORE2 and builds a fully on-chain tokenURI as a base64-
///         encoded data: JSON containing an on-chain placeholder image (or an
///         Arweave-pinned preview once the off-chain listener writes the txid)
///         plus an `animation_url` data:text/html URI that inlines the script
///         and token hash. The canonical art lives in `animation_url` and has
///         zero off-chain dependencies.
///
///         Every mint pushes 95% of mintPrice to the artist, 5% to the
///         platform wallet, and the full $2-equivalent storage fee to the
///         storage-fee wallet — all in the same atomic transaction. Zero fee
///         balances ever accumulate in this contract.
///
///         Immutable. No admin. No pause. No withdraw functions exist.
contract PDProject is ERC721, IERC2981 {
    using LibString for uint256;
    using LibString for address;

    // ─── Fee Constants ───────────────────────────────────────────────────

    uint256 private constant ARTIST_BPS = 9_500;     // 95% of mintPrice
    uint256 private constant PLATFORM_BPS = 500;     // 5%  of mintPrice
    uint256 private constant BPS_DENOM = 10_000;
    uint256 private constant ROYALTY_BPS = 500;      // 5% total secondary (3/2 via splitter)

    /// @notice Hard per-tx mint cap. Floor on grief vectors at the transaction
    ///         level (the per-Project supply cap is the actual scarcity bound).
    uint256 public constant MAX_MINT_PER_TX = 22;

    // ─── Oracle Constants ────────────────────────────────────────────────

    /// @dev Storage fee target: $2 USD-equivalent per mint.
    uint256 private constant STORAGE_FEE_USD = 2;

    /// @dev Chainlink heartbeat staleness threshold.
    uint256 private constant CHAINLINK_STALENESS = 1 hours;

    /// @dev Uniswap V3 arithmetic-mean TWAP window.
    uint32 private constant TWAP_WINDOW = 1800; // 30 minutes

    /// @dev Chainlink ETH/USD answer is 8 decimals; we normalize to 18 by * 1e10.
    uint256 private constant CHAINLINK_TO_18 = 1e10;

    /// @dev USDC is 6 decimals; we normalize to 18 by * 1e12 (per 1e18 base).
    uint256 private constant USDC_TO_18 = 1e12;

    /// @dev Storage fee numerator: $2 * 1e36 / ethUsd18 gives wei.
    uint256 private constant STORAGE_FEE_NUM = STORAGE_FEE_USD * 1e36;

    // ─── Immutable State ─────────────────────────────────────────────────

    address public immutable artist;
    address public immutable factory;
    address public immutable paymentSplitter;
    uint256 public immutable mintPrice;
    uint256 public immutable maxSupply;

    // ─── Storage ─────────────────────────────────────────────────────────

    /// @notice Human-readable Project description, set at creation. Used in tokenURI JSON.
    ///         Treat as effectively immutable — no setter exists. Artist-supplied;
    ///         must be plain text without JSON-breaking characters.
    string public description;

    /// @notice SSTORE2 pointers to on-chain script chunks, in order.
    address[] internal _scriptPointers;

    /// @notice Total tokens minted. Token IDs start at 1 and are strictly increasing.
    uint256 public totalMinted;

    /// @notice Deterministic per-token hash — the seed for generative output.
    mapping(uint256 => bytes32) public tokenHashes;

    /// @notice Per-token Arweave path-manifest txid (write-once). Zero means not yet set;
    ///         tokenURI returns the on-chain PRESERVING PREVIEW placeholder until set.
    mapping(uint256 => bytes32) public tokenArweaveManifests;

    // ─── Errors ──────────────────────────────────────────────────────────

    error NotWriter();
    error IncorrectPayment();
    error MaxSupplyReached();
    error QuantityZero();
    error QuantityExceedsTxCap();
    error TransferFailed();
    error TxidAlreadySet();
    error ZeroTxid();
    error OracleFailed();
    error NonexistentToken();

    // ─── Events ──────────────────────────────────────────────────────────

    event Minted(address indexed minter, uint256 indexed tokenId, bytes32 tokenHash);
    event ArweaveTxidSet(uint256 indexed tokenId, bytes32 arweaveManifestTxid);
    /// @notice Emitted once per mint batch with cumulative shares. `tokenId` is
    ///         the first tokenId of the batch (anchor for indexer correlation
    ///         with the contiguous Minted events that follow).
    event MintFeeDistributed(
        uint256 indexed tokenId,
        uint256 artistShare,
        uint256 platformShare,
        uint256 storageShare
    );

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(
        string memory _name,
        string memory _symbol,
        address _artist,
        uint256 _mintPrice,
        uint256 _maxSupply,
        address _splitter,
        bytes[] memory _scriptChunks,
        string memory _description
    ) ERC721(_name, _symbol) {
        artist = _artist;
        factory = msg.sender;
        paymentSplitter = _splitter;
        mintPrice = _mintPrice;
        maxSupply = _maxSupply;
        description = _description;

        uint256 len = _scriptChunks.length;
        for (uint256 i; i < len;) {
            _scriptPointers.push(SSTORE2.write(_scriptChunks[i]));
            unchecked { ++i; }
        }
    }

    // ─── Minting (Push Pattern) ──────────────────────────────────────────

    /// @notice Mint `quantity` tokens with full live fee distribution.
    ///         Caller must supply exactly `(mintPrice + storageFeeWei) * quantity`.
    ///
    ///         Order of operations is strict CEI:
    ///         1. Checks — quantity, supply cap, oracle read, exact payment
    ///         2. Effects — mint tokens, set hashes, emit Minted + MintFeeDistributed
    ///         3. Interactions — push artist, push platform, push storage
    ///
    ///         All three pushes happen in the same transaction. If any
    ///         recipient reverts, the entire mint reverts atomically and no
    ///         funds are stuck anywhere.
    function mint(uint256 quantity) external payable {
        // ── Checks ──
        if (quantity == 0) revert QuantityZero();
        if (quantity > MAX_MINT_PER_TX) revert QuantityExceedsTxCap();
        uint256 startingMinted = totalMinted;
        if (startingMinted + quantity > maxSupply) revert MaxSupplyReached();

        uint256 ethUsd18 = _getEthUsdPrice18();
        uint256 storageFeeWei = STORAGE_FEE_NUM / ethUsd18; // wei for $2

        uint256 mintPriceTotal = mintPrice * quantity;
        uint256 storageTotal = storageFeeWei * quantity;
        uint256 required = mintPriceTotal + storageTotal;
        if (msg.value != required) revert IncorrectPayment();

        uint256 artistShare = (mintPriceTotal * ARTIST_BPS) / BPS_DENOM;
        // Use the complement so artist + platform always equal mintPriceTotal exactly,
        // with no rounding dust trapped in the contract.
        uint256 platformShare = mintPriceTotal - artistShare;

        // ── Effects ──
        bytes32 blockHash = blockhash(block.number - 1);
        address minter = msg.sender;
        uint256 firstTokenId = startingMinted + 1;

        for (uint256 i; i < quantity;) {
            uint256 tokenId;
            unchecked { tokenId = ++totalMinted; } // bounded above by supply check
            bytes32 hash = keccak256(abi.encodePacked(tokenId, blockHash, minter));
            tokenHashes[tokenId] = hash;
            _mint(minter, tokenId);
            emit Minted(minter, tokenId, hash);
            unchecked { ++i; }
        }

        emit MintFeeDistributed(firstTokenId, artistShare, platformShare, storageTotal);

        // ── Interactions ──
        IPDFactory f = IPDFactory(factory);
        _push(artist, artistShare);
        _push(f.platformWallet(), platformShare);
        _push(f.storageFeeWallet(), storageTotal);
    }

    /// @dev Push ETH to a recipient; revert the whole mint on any failure.
    function _push(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ─── Arweave Txid Write (writer-only, write-once) ────────────────────

    /// @notice Bind an Arweave path-manifest txid to a token. Write-once.
    ///         Only the factory's current storage-fee writer can call. The
    ///         writer can be rotated by admin (key rotation), but it cannot
    ///         overwrite an existing binding — once a token's preview is
    ///         pinned, that pin is permanent.
    function setArweaveTxid(uint256 tokenId, bytes32 arweaveManifestTxid) external {
        if (msg.sender != IPDFactory(factory).storageFeeWriter()) revert NotWriter();
        if (arweaveManifestTxid == bytes32(0)) revert ZeroTxid();
        if (tokenArweaveManifests[tokenId] != bytes32(0)) revert TxidAlreadySet();
        // Implicit existence check: token must have been minted.
        if (tokenId == 0 || tokenId > totalMinted) revert NonexistentToken();

        tokenArweaveManifests[tokenId] = arweaveManifestTxid;
        emit ArweaveTxidSet(tokenId, arweaveManifestTxid);
    }

    // ─── Oracle Cascade ──────────────────────────────────────────────────

    /// @notice ETH/USD price scaled to 18 decimals.
    ///         Cascade: Chainlink → retry once → Uniswap V3 TWAP → revert.
    function _getEthUsdPrice18() internal view returns (uint256) {
        address feed = IPDFactory(factory).chainlinkFeed();

        // Primary attempt
        uint256 price = _tryChainlink(feed);
        if (price != 0) return price;

        // One retry — defends against transient aggregator-call reverts in the
        // same transaction window. Same-block result will match, but the retry
        // re-runs the try/catch so a momentary network/proxy hiccup is absorbed.
        price = _tryChainlink(feed);
        if (price != 0) return price;

        // Fallback: Uniswap V3 30-minute arithmetic-mean TWAP
        price = _tryUniswapTwap();
        if (price != 0) return price;

        revert OracleFailed();
    }

    /// @dev Returns 18-decimal ETH/USD price, or 0 on any failure or staleness.
    function _tryChainlink(address feed) internal view returns (uint256) {
        try IChainlinkAggregator(feed).latestRoundData() returns (
            uint80 /* roundId */,
            int256 answer,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 /* answeredInRound */
        ) {
            if (
                answer > 0 &&
                updatedAt > 0 &&
                block.timestamp >= updatedAt &&
                block.timestamp - updatedAt <= CHAINLINK_STALENESS
            ) {
                return uint256(answer) * CHAINLINK_TO_18;
            }
        } catch { /* fall through to caller */ }
        return 0;
    }

    /// @dev Returns 18-decimal ETH/USD price from Uniswap V3 TWAP, or 0 on
    ///      failure. Folds both the `consult` (which can revert if the pool
    ///      lacks observation history) and the `getQuoteAtTick` math (which
    ///      can revert on extreme-tick overflow) into a single external view
    ///      so the surrounding try/catch boundary catches every internal
    ///      revert and surfaces it cleanly as OracleFailed when the cascade
    ///      reaches its bottom.
    function _tryUniswapTwap() internal view returns (uint256) {
        address pool = IPDFactory(factory).uniswapV3Pool();

        try this.peekUniswapEthUsdPrice18(pool) returns (uint256 price18) {
            return price18;
        } catch {
            return 0;
        }
    }

    /// @notice External wrapper that performs the full Uniswap V3 TWAP read
    ///         and quote math in one view call. Marked external so it can be
    ///         called via `this.` for the try/catch boundary. View-only — safe.
    /// @dev    Returns the 18-decimal ETH/USD price, or 0 if the pool quote is
    ///         zero. Any internal revert (insufficient observations, extreme
    ///         tick overflow in getQuoteAtTick, etc.) propagates out and is
    ///         absorbed by the caller's try/catch.
    function peekUniswapEthUsdPrice18(address pool) external view returns (uint256) {
        IPDFactory f = IPDFactory(factory);
        int24 tick = OracleLibrary.consult(pool, TWAP_WINDOW);
        uint256 usdcPer1Eth = OracleLibrary.getQuoteAtTick(tick, 1e18, f.weth(), f.usdc());
        if (usdcPer1Eth == 0) return 0;
        return usdcPer1Eth * USDC_TO_18;
    }

    /// @notice Public view: current storage fee in wei. Frontend uses this to
    ///         compute exact msg.value before sending the mint tx.
    function currentStorageFeeWei() external view returns (uint256) {
        return STORAGE_FEE_NUM / _getEthUsdPrice18();
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
    function getScript() public view returns (string memory script) {
        uint256 len = _scriptPointers.length;
        for (uint256 i; i < len;) {
            script = string.concat(script, string(SSTORE2.read(_scriptPointers[i])));
            unchecked { ++i; }
        }
    }

    // ─── Fully On-Chain Metadata ─────────────────────────────────────────

    /// @notice tokenURI returns a self-contained `data:application/json;base64,…`
    ///         URI. `image` is either the Arweave preview (once the listener has
    ///         written the txid) or an on-chain PRESERVING PREVIEW SVG placeholder.
    ///         `animation_url` is the canonical generative HTML — fully on-chain.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        string memory imageField = _buildImageField(tokenId);
        string memory animationField = _buildAnimationField(tokenId);

        // Defensive: the factory validates name + description against JSON-
        // breaking characters at createProject time, so artist-supplied input
        // should never reach here unescaped. We escape anyway — belt and
        // suspenders. ERC721 `name()` reads back the constructor-stored value
        // unchanged, so the same characters apply.
        bytes memory json = abi.encodePacked(
            '{"name":"',
            _jsonEscape(name()),
            ' #',
            tokenId.toString(),
            '","description":"',
            _jsonEscape(description),
            '","image":"',
            imageField,
            '","animation_url":"',
            animationField,
            '","attributes":',
            _buildAttributes(tokenId),
            '}'
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(json)
        );
    }

    /// @dev JSON string-content escaper per RFC 8259 §7. Quotes and backslashes
    ///      get their two-char escape; the common whitespace control codes get
    ///      their short escape (\b, \t, \n, \f, \r); every other control byte
    ///      and DEL (0x7F) becomes a \u00XX sequence. UTF-8 multibyte payload
    ///      (>= 0x80) passes through verbatim.
    function _jsonEscape(string memory input) internal pure returns (string memory) {
        bytes memory data = bytes(input);
        uint256 len = data.length;
        // Worst case: every byte expands to a 6-char \u00XX sequence.
        bytes memory out = new bytes(len * 6);
        uint256 j;
        for (uint256 i; i < len;) {
            bytes1 b = data[i];
            if (b == 0x22) {
                out[j] = 0x5C; out[j + 1] = 0x22; j += 2;            // \"
            } else if (b == 0x5C) {
                out[j] = 0x5C; out[j + 1] = 0x5C; j += 2;            // \\
            } else if (b == 0x08) {
                out[j] = 0x5C; out[j + 1] = 0x62; j += 2;            // \b
            } else if (b == 0x09) {
                out[j] = 0x5C; out[j + 1] = 0x74; j += 2;            // \t
            } else if (b == 0x0A) {
                out[j] = 0x5C; out[j + 1] = 0x6E; j += 2;            // \n
            } else if (b == 0x0C) {
                out[j] = 0x5C; out[j + 1] = 0x66; j += 2;            // \f
            } else if (b == 0x0D) {
                out[j] = 0x5C; out[j + 1] = 0x72; j += 2;            // \r
            } else if (uint8(b) < 0x20 || uint8(b) == 0x7F) {
                uint8 hi = uint8(b) >> 4;
                uint8 lo = uint8(b) & 0x0F;
                out[j]     = 0x5C; // \
                out[j + 1] = 0x75; // u
                out[j + 2] = 0x30; // 0
                out[j + 3] = 0x30; // 0
                out[j + 4] = bytes1(hi < 10 ? hi + 0x30 : hi + 0x57); // 0-9 / a-f
                out[j + 5] = bytes1(lo < 10 ? lo + 0x30 : lo + 0x57);
                j += 6;
            } else {
                out[j] = b; j += 1;
            }
            unchecked { ++i; }
        }
        // Truncate the output bytes array to its true length.
        assembly {
            mstore(out, j)
        }
        return string(out);
    }

    function _buildImageField(uint256 tokenId) internal view returns (string memory) {
        bytes32 txid = tokenArweaveManifests[tokenId];
        if (txid == bytes32(0)) {
            // On-chain PRESERVING PREVIEW SVG placeholder (universal across all Projects)
            return string.concat(
                "data:image/svg+xml;base64,",
                Base64.encode(bytes(_preservingPreviewSvg()))
            );
        }
        return string.concat("ar://", LibString.toHexStringNoPrefix(uint256(txid), 32), "/preview.webp");
    }

    function _preservingPreviewSvg() internal pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000">',
            '<rect width="1000" height="1000" fill="#0a0a0a"/>',
            '<text x="500" y="510" text-anchor="middle" fill="#fafafa" ',
            'font-family="ui-monospace, SFMono-Regular, Menlo, Monaco, monospace" ',
            'font-size="44" letter-spacing="8">PRESERVING PREVIEW</text>',
            '</svg>'
        );
    }

    function _buildAnimationField(uint256 tokenId) internal view returns (string memory) {
        bytes32 hash = tokenHashes[tokenId];
        bytes memory html = abi.encodePacked(
            '<!DOCTYPE html><html><head><meta charset="utf-8">',
            '<meta name="viewport" content="width=device-width,initial-scale=1">',
            '<style>html,body{margin:0;padding:0;background:#0a0a0a;overflow:hidden;}canvas{display:block;}</style>',
            '</head><body><script>var tokenData={hash:"0x',
            LibString.toHexStringNoPrefix(uint256(hash), 32),
            '",tokenId:"',
            tokenId.toString(),
            '"};\n',
            getScript(),
            '\n</script></body></html>'
        );
        return string.concat("data:text/html;base64,", Base64.encode(html));
    }

    function _buildAttributes(uint256 tokenId) internal view returns (string memory) {
        bytes32 hash = tokenHashes[tokenId];
        return string.concat(
            '[',
            '{"trait_type":"Token Hash","value":"0x',
            LibString.toHexStringNoPrefix(uint256(hash), 32),
            '"},',
            '{"trait_type":"Token Number","value":"',
            tokenId.toString(),
            '"},',
            '{"trait_type":"Artist","value":"',
            artist.toHexString(),
            '"}',
            ']'
        );
    }

    // ─── EIP-2981 Royalties ──────────────────────────────────────────────

    function royaltyInfo(
        uint256, /* tokenId — same config for all tokens */
        uint256 salePrice
    ) external view override returns (address receiver, uint256 royaltyAmount) {
        receiver = paymentSplitter;
        royaltyAmount = (salePrice * ROYALTY_BPS) / BPS_DENOM;
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
