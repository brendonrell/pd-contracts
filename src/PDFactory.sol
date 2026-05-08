// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PDCollection} from "./PDCollection.sol";
import {PaymentSplitter} from "./PaymentSplitter.sol";

/// @title PDFactory
/// @notice The deployer and registry for Price Discussion — a curated generative
///         art minting platform on Ethereum mainnet.
///
///         Deploys PDCollection + PaymentSplitter pairs per artist drop.
///         Maintains the artist whitelist, enforces the 60-day cooldown,
///         and handles platform fee withdrawal.
///
///         Immutable logic. Admin is a single address, transferable for multisig.
contract PDFactory {
    // ─── Constants ───────────────────────────────────────────────────────

    /// @notice 60-day cooldown between artist collection launches.
    uint256 public constant COOLDOWN_PERIOD = 60 days;

    /// @notice Maximum editions per collection.
    uint256 public constant MAX_SUPPLY_CAP = 10_000;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice Platform admin. Transferable for multisig migration.
    address public admin;

    /// @notice Platform wallet — receives primary fees + platform royalty share.
    address public platformWallet;

    /// @notice Base URI for token metadata. Collections delegate tokenURI() here.
    ///         Updatable so metadata endpoint can migrate without redeploying collections.
    string public baseTokenURI;

    mapping(address => bool) public whitelistedArtists;
    mapping(address => uint256) public lastCollectionTimestamp;

    /// @notice All deployed collection addresses, in order of deployment.
    address[] public collections;

    mapping(address => bool) public isCollection;
    mapping(address => address[]) public artistCollections;

    // ─── Errors ──────────────────────────────────────────────────────────

    error NotAdmin();
    error ZeroAddress();
    error ArtistNotWhitelisted();
    error CooldownActive(uint256 availableAt);
    error MaxSupplyExceeded();
    error MaxSupplyZero();
    error TransferFailed();
    error NoScriptData();
    error InvalidRange();

    // ─── Events ──────────────────────────────────────────────────────────

    event CollectionCreated(
        address indexed collection,
        address indexed artist,
        address indexed splitter,
        string name,
        uint256 maxSupply,
        uint256 mintPrice
    );

    event ArtistWhitelisted(address indexed artist);
    event ArtistRemoved(address indexed artist);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event PlatformWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event BaseTokenURIUpdated(string newURI);
    event FeesWithdrawn(address indexed collection, address indexed to, uint256 amount);
    event BatchFeesWithdrawn(address indexed to, uint256 total, uint256 collectionCount);

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(
        address _admin,
        address _platformWallet,
        string memory _baseTokenURI
    ) {
        if (_admin == address(0) || _platformWallet == address(0))
            revert ZeroAddress();
        admin = _admin;
        platformWallet = _platformWallet;
        baseTokenURI = _baseTokenURI;
    }

    // ─── Collection Deployment ───────────────────────────────────────────

    /// @notice Deploy a new generative art collection.
    ///         Only whitelisted artists. Enforces 60-day cooldown and 10k cap.
    ///         Deploys both a PDCollection and its PaymentSplitter.
    function createCollection(
        string calldata name,
        string calldata symbol,
        uint256 maxSupply,
        uint256 mintPrice,
        bytes[] calldata scriptChunks
    ) external returns (address collection) {
        address artist = msg.sender;

        // ── Checks ──
        if (!whitelistedArtists[artist]) revert ArtistNotWhitelisted();
        if (maxSupply == 0) revert MaxSupplyZero();
        if (maxSupply > MAX_SUPPLY_CAP) revert MaxSupplyExceeded();
        if (scriptChunks.length == 0) revert NoScriptData();

        // Cooldown: only meaningful after an artist's first deploy.
        // Explicit null check — works in all environments (including tests where
        // block.timestamp can be small).
        uint256 lastTs = lastCollectionTimestamp[artist];
        if (lastTs != 0) {
            uint256 availableAt = lastTs + COOLDOWN_PERIOD;
            if (block.timestamp < availableAt) revert CooldownActive(availableAt);
        }

        // ── Effects/Interactions: deploy splitter then collection ──
        PaymentSplitter splitter = new PaymentSplitter(artist, platformWallet);

        PDCollection coll = new PDCollection(
            name,
            symbol,
            artist,
            mintPrice,
            maxSupply,
            address(splitter),
            scriptChunks
        );

        collection = address(coll);

        lastCollectionTimestamp[artist] = block.timestamp;
        collections.push(collection);
        isCollection[collection] = true;
        artistCollections[artist].push(collection);

        emit CollectionCreated(
            collection,
            artist,
            address(splitter),
            name,
            maxSupply,
            mintPrice
        );
    }

    // ─── Artist Whitelist ────────────────────────────────────────────────

    function whitelistArtist(address artist) external onlyAdmin {
        if (artist == address(0)) revert ZeroAddress();
        whitelistedArtists[artist] = true;
        emit ArtistWhitelisted(artist);
    }

    /// @notice Remove an artist. Does not affect already-deployed collections.
    function removeArtist(address artist) external onlyAdmin {
        if (artist == address(0)) revert ZeroAddress(); // consistency with whitelistArtist
        whitelistedArtists[artist] = false;
        emit ArtistRemoved(artist);
    }

    // ─── Platform Fee Withdrawal ─────────────────────────────────────────

    /// @notice Withdraw accumulated platform fees from a single collection.
    ///         Uses balance delta (so pre-existing factory ETH isn't swept).
    ///         PDCollection.withdraw() is a no-op when balance is zero — so
    ///         this function doesn't revert on already-swept collections.
    function withdrawFrom(address collection) external onlyAdmin {
        uint256 balanceBefore = address(this).balance;
        PDCollection(collection).withdraw();
        uint256 received = address(this).balance - balanceBefore;

        if (received > 0) {
            (bool success,) = platformWallet.call{value: received}("");
            if (!success) revert TransferFailed();
            emit FeesWithdrawn(collection, platformWallet, received);
        }
    }

    /// @notice Paginated batch withdraw — sweeps [start, end) from the collections array.
    ///         Use this as the platform scales past the point where a full sweep
    ///         would exceed block gas. Range is clamped to array length.
    function batchWithdrawRange(uint256 start, uint256 end) external onlyAdmin {
        uint256 len = collections.length;
        if (end > len) end = len;
        if (start >= end) revert InvalidRange();

        uint256 balanceBefore = address(this).balance;

        for (uint256 i = start; i < end;) {
            // try/catch keeps this safe if a future collection ever misbehaves.
            try PDCollection(collections[i]).withdraw() {} catch {}
            unchecked { ++i; }
        }

        uint256 received = address(this).balance - balanceBefore;
        if (received > 0) {
            (bool success,) = platformWallet.call{value: received}("");
            if (!success) revert TransferFailed();
            emit BatchFeesWithdrawn(platformWallet, received, end - start);
        }
    }

    /// @notice Convenience sweep of every collection. Safe up to ~30-50 collections
    ///         before block gas becomes a concern; switch to batchWithdrawRange past that.
    function batchWithdraw() external onlyAdmin {
        uint256 balanceBefore = address(this).balance;
        uint256 len = collections.length;

        for (uint256 i; i < len;) {
            try PDCollection(collections[i]).withdraw() {} catch {}
            unchecked { ++i; }
        }

        uint256 received = address(this).balance - balanceBefore;
        if (received > 0) {
            (bool success,) = platformWallet.call{value: received}("");
            if (!success) revert TransferFailed();
            emit BatchFeesWithdrawn(platformWallet, received, len);
        }
    }

    // ─── Admin Management ────────────────────────────────────────────────

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function setPlatformWallet(address newWallet) external onlyAdmin {
        if (newWallet == address(0)) revert ZeroAddress();
        emit PlatformWalletUpdated(platformWallet, newWallet);
        platformWallet = newWallet;
    }

    function setBaseTokenURI(string calldata newURI) external onlyAdmin {
        baseTokenURI = newURI;
        emit BaseTokenURIUpdated(newURI);
    }

    // ─── View Functions ──────────────────────────────────────────────────

    function collectionCount() external view returns (uint256) {
        return collections.length;
    }

    function artistCollectionCount(address artist) external view returns (uint256) {
        return artistCollections[artist].length;
    }

    /// @notice Full collection list for an artist — used by frontend profile pages.
    function getArtistCollections(address artist) external view returns (address[] memory) {
        return artistCollections[artist];
    }

    /// @notice Seconds remaining on an artist's cooldown. Returns 0 if clear or never deployed.
    function cooldownRemaining(address artist) external view returns (uint256) {
        uint256 lastTs = lastCollectionTimestamp[artist];
        if (lastTs == 0) return 0;
        uint256 availableAt = lastTs + COOLDOWN_PERIOD;
        if (block.timestamp >= availableAt) return 0;
        return availableAt - block.timestamp;
    }

    /// @notice Is artist whitelisted AND off cooldown right now?
    function canCreateCollection(address artist) external view returns (bool) {
        if (!whitelistedArtists[artist]) return false;
        uint256 lastTs = lastCollectionTimestamp[artist];
        if (lastTs == 0) return true;
        return block.timestamp >= lastTs + COOLDOWN_PERIOD;
    }

    // ─── Receive ─────────────────────────────────────────────────────────

    /// @notice Accept ETH from collection withdrawals.
    receive() external payable {}
}
