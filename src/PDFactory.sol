// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PDProject} from "./PDProject.sol";
import {PaymentSplitter} from "./PaymentSplitter.sol";

/// @title PDFactory
/// @notice The deployer and registry for Price Discussion — a curated generative
///         art minting platform on Ethereum mainnet.
///
///         Deploys PDProject + PaymentSplitter pairs per artist drop.
///         Maintains the artist whitelist, enforces the 60-day cooldown.
///
///         Admin scope is intentionally narrow:
///           - whitelist artists (curation)
///           - rotate platform / storage-fee wallets
///           - rotate storage-fee writer (Arweave listener key)
///           - transfer admin (multisig migration)
///
///         Admin has ZERO reach into deployed PDProject metadata behavior
///         (no setBaseTokenURI exists anywhere) and ZERO contract-held funds
///         to sweep — every mint pushes all three fee shares live to their
///         destination wallets in the mint transaction itself.
///
///         Immutable per-project contracts. No pause. No upgrades.
contract PDFactory {
    // ─── Constants ───────────────────────────────────────────────────────

    /// @notice 60-day cooldown between artist Project launches.
    uint256 public constant COOLDOWN_PERIOD = 60 days;

    /// @notice Maximum Outputs per Project.
    uint256 public constant MAX_SUPPLY_CAP = 10_000;

    // ─── Immutable Oracle Wiring ─────────────────────────────────────────

    /// @notice Chainlink ETH/USD price feed (mainnet: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419).
    ///         Locked at deploy time — cannot be rotated.
    address public immutable chainlinkFeed;

    /// @notice Uniswap V3 WETH/USDC 0.05% pool used as TWAP fallback
    ///         (mainnet: 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640).
    ///         Locked at deploy time — cannot be rotated.
    address public immutable uniswapV3Pool;

    /// @notice WETH token address used as the base of the TWAP quote
    ///         (mainnet: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2).
    ///         Parameterized rather than constant so the same bytecode deploys
    ///         on testnet against mock tokens.
    address public immutable weth;

    /// @notice USDC token address used as the quote of the TWAP quote
    ///         (mainnet: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48).
    address public immutable usdc;

    // ─── Mutable Admin / Wallet State ────────────────────────────────────

    /// @notice Platform admin. Transferable for multisig migration.
    address public admin;

    /// @notice Receives the 5% mint-price share on every mint, live.
    ///         Must accept ETH cleanly (EOA or simple multisig with non-reverting receive).
    address public platformWallet;

    /// @notice Receives the $2-equivalent storage fee on every mint, live.
    ///         Must accept ETH cleanly (EOA or simple multisig with non-reverting receive).
    address public storageFeeWallet;

    /// @notice Off-chain Arweave listener key — the only address authorized to
    ///         call setArweaveTxid() on PDProject contracts. Rotatable by admin
    ///         (key rotation only — confers zero metadata mutability beyond
    ///         the write-once Arweave txid binding per token).
    address public storageFeeWriter;

    // ─── Registry State ──────────────────────────────────────────────────

    mapping(address => bool) public whitelistedArtists;
    mapping(address => uint256) public lastProjectTimestamp;

    /// @notice All deployed Project addresses, in order of deployment.
    address[] public projects;

    mapping(address => bool) public isProject;
    mapping(address => address[]) public artistProjects;

    // ─── Errors ──────────────────────────────────────────────────────────

    error NotAdmin();
    error ZeroAddress();
    error ArtistNotWhitelisted();
    error CooldownActive(uint256 availableAt);
    error MaxSupplyExceeded();
    error MaxSupplyZero();
    error NoScriptData();
    error InvalidCharacter();

    // ─── Events ──────────────────────────────────────────────────────────

    event ProjectCreated(
        address indexed project,
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
    event StorageFeeWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event StorageFeeWriterUpdated(address indexed oldWriter, address indexed newWriter);

    // ─── Modifiers ───────────────────────────────────────────────────────

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    constructor(
        address _admin,
        address _platformWallet,
        address _storageFeeWallet,
        address _storageFeeWriter,
        address _chainlinkFeed,
        address _uniswapV3Pool,
        address _weth,
        address _usdc
    ) {
        if (
            _admin == address(0) ||
            _platformWallet == address(0) ||
            _storageFeeWallet == address(0) ||
            _storageFeeWriter == address(0) ||
            _chainlinkFeed == address(0) ||
            _uniswapV3Pool == address(0) ||
            _weth == address(0) ||
            _usdc == address(0)
        ) revert ZeroAddress();

        admin = _admin;
        platformWallet = _platformWallet;
        storageFeeWallet = _storageFeeWallet;
        storageFeeWriter = _storageFeeWriter;
        chainlinkFeed = _chainlinkFeed;
        uniswapV3Pool = _uniswapV3Pool;
        weth = _weth;
        usdc = _usdc;
    }

    // ─── Project Deployment ──────────────────────────────────────────────

    /// @notice Deploy a new generative art Project.
    ///         Only whitelisted artists. Enforces 60-day cooldown and 10k cap.
    ///         Deploys both a PDProject and its PaymentSplitter.
    function createProject(
        string calldata name,
        string calldata symbol,
        uint256 maxSupply,
        uint256 mintPrice,
        bytes[] calldata scriptChunks,
        string calldata description
    ) external returns (address project) {
        address artist = msg.sender;

        // ── Checks ──
        if (!whitelistedArtists[artist]) revert ArtistNotWhitelisted();
        if (maxSupply == 0) revert MaxSupplyZero();
        if (maxSupply > MAX_SUPPLY_CAP) revert MaxSupplyExceeded();
        if (scriptChunks.length == 0) revert NoScriptData();

        // Reject any byte that would break the on-chain tokenURI JSON: control
        // bytes (0x00-0x1F + 0x7F), double-quote (0x22), backslash (0x5C). The
        // tokenURI builder also escapes defensively — this is the upstream
        // half of belt-and-suspenders. UTF-8 multibyte characters (>= 0x80)
        // pass through.
        _assertJsonSafe(bytes(name));
        _assertJsonSafe(bytes(description));

        // Cooldown: only meaningful after an artist's first deploy.
        uint256 lastTs = lastProjectTimestamp[artist];
        if (lastTs != 0) {
            uint256 availableAt = lastTs + COOLDOWN_PERIOD;
            if (block.timestamp < availableAt) revert CooldownActive(availableAt);
        }

        // ── Effects/Interactions: deploy splitter then Project ──
        PaymentSplitter splitter = new PaymentSplitter(artist, address(this));

        PDProject proj = new PDProject(
            name,
            symbol,
            artist,
            mintPrice,
            maxSupply,
            address(splitter),
            scriptChunks,
            description
        );

        project = address(proj);

        lastProjectTimestamp[artist] = block.timestamp;
        projects.push(project);
        isProject[project] = true;
        artistProjects[artist].push(project);

        emit ProjectCreated(
            project,
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

    /// @notice Remove an artist. Does not affect already-deployed Projects.
    function removeArtist(address artist) external onlyAdmin {
        if (artist == address(0)) revert ZeroAddress();
        whitelistedArtists[artist] = false;
        emit ArtistRemoved(artist);
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

    function setStorageFeeWallet(address newWallet) external onlyAdmin {
        if (newWallet == address(0)) revert ZeroAddress();
        emit StorageFeeWalletUpdated(storageFeeWallet, newWallet);
        storageFeeWallet = newWallet;
    }

    function setStorageFeeWriter(address newWriter) external onlyAdmin {
        if (newWriter == address(0)) revert ZeroAddress();
        emit StorageFeeWriterUpdated(storageFeeWriter, newWriter);
        storageFeeWriter = newWriter;
    }

    // ─── Internal Helpers ────────────────────────────────────────────────

    /// @dev Reject any byte that would break the on-chain tokenURI JSON.
    ///      Disallowed: control bytes 0x00-0x1F, DEL 0x7F, double-quote 0x22,
    ///      backslash 0x5C. UTF-8 multibyte characters (>= 0x80) are permitted
    ///      and pass through verbatim into the JSON string.
    function _assertJsonSafe(bytes memory data) private pure {
        uint256 len = data.length;
        for (uint256 i; i < len;) {
            uint8 b = uint8(data[i]);
            if (b < 0x20 || b == 0x22 || b == 0x5C || b == 0x7F) revert InvalidCharacter();
            unchecked { ++i; }
        }
    }

    // ─── View Functions ──────────────────────────────────────────────────

    function projectCount() external view returns (uint256) {
        return projects.length;
    }

    function artistProjectCount(address artist) external view returns (uint256) {
        return artistProjects[artist].length;
    }

    /// @notice Full Project list for an artist — used by frontend profile pages.
    function getArtistProjects(address artist) external view returns (address[] memory) {
        return artistProjects[artist];
    }

    /// @notice Seconds remaining on an artist's cooldown. Returns 0 if clear or never deployed.
    function cooldownRemaining(address artist) external view returns (uint256) {
        uint256 lastTs = lastProjectTimestamp[artist];
        if (lastTs == 0) return 0;
        uint256 availableAt = lastTs + COOLDOWN_PERIOD;
        if (block.timestamp >= availableAt) return 0;
        return availableAt - block.timestamp;
    }

    /// @notice Is artist whitelisted AND off cooldown right now?
    function canCreateProject(address artist) external view returns (bool) {
        if (!whitelistedArtists[artist]) return false;
        uint256 lastTs = lastProjectTimestamp[artist];
        if (lastTs == 0) return true;
        return block.timestamp >= lastTs + COOLDOWN_PERIOD;
    }
}
