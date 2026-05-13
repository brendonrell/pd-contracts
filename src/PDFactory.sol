// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PDProject} from "./PDProject.sol";
import {PaymentSplitter} from "./PaymentSplitter.sol";

/// @title PDFactory
/// @notice The deployer and registry for Price Discussion — a curated generative
///         art minting platform on Ethereum mainnet.
///
///         Deploys PDProject + PaymentSplitter pairs per artist drop.
///         Maintains the artist whitelist, enforces the 60-day cooldown,
///         and handles platform fee withdrawal.
///
///         Immutable logic. Admin is a single address, transferable for multisig.
contract PDFactory {
    // ─── Constants ───────────────────────────────────────────────────────

    /// @notice 60-day cooldown between artist Project launches.
    uint256 public constant COOLDOWN_PERIOD = 60 days;

    /// @notice Maximum Outputs per Project.
    uint256 public constant MAX_SUPPLY_CAP = 10_000;

    // ─── State ───────────────────────────────────────────────────────────

    /// @notice Platform admin. Transferable for multisig migration.
    address public admin;

    /// @notice Platform wallet — receives primary fees + platform royalty share.
    address public platformWallet;

    /// @notice Base URI for token metadata. Projects delegate tokenURI() here.
    ///         Updatable so metadata endpoint can migrate without redeploying Projects.
    string public baseTokenURI;

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
    error TransferFailed();
    error NoScriptData();
    error InvalidRange();

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
    event BaseTokenURIUpdated(string newURI);
    event FeesWithdrawn(address indexed project, address indexed to, uint256 amount);
    event BatchFeesWithdrawn(address indexed to, uint256 total, uint256 projectCount);

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

    // ─── Project Deployment ──────────────────────────────────────────────

    /// @notice Deploy a new generative art Project.
    ///         Only whitelisted artists. Enforces 60-day cooldown and 10k cap.
    ///         Deploys both a PDProject and its PaymentSplitter.
    function createProject(
        string calldata name,
        string calldata symbol,
        uint256 maxSupply,
        uint256 mintPrice,
        bytes[] calldata scriptChunks
    ) external returns (address project) {
        address artist = msg.sender;

        // ── Checks ──
        if (!whitelistedArtists[artist]) revert ArtistNotWhitelisted();
        if (maxSupply == 0) revert MaxSupplyZero();
        if (maxSupply > MAX_SUPPLY_CAP) revert MaxSupplyExceeded();
        if (scriptChunks.length == 0) revert NoScriptData();

        // Cooldown: only meaningful after an artist's first deploy.
        // Explicit null check — works in all environments (including tests where
        // block.timestamp can be small).
        uint256 lastTs = lastProjectTimestamp[artist];
        if (lastTs != 0) {
            uint256 availableAt = lastTs + COOLDOWN_PERIOD;
            if (block.timestamp < availableAt) revert CooldownActive(availableAt);
        }

        // ── Effects/Interactions: deploy splitter then Project ──
        PaymentSplitter splitter = new PaymentSplitter(artist, platformWallet);

        PDProject proj = new PDProject(
            name,
            symbol,
            artist,
            mintPrice,
            maxSupply,
            address(splitter),
            scriptChunks
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
        if (artist == address(0)) revert ZeroAddress(); // consistency with whitelistArtist
        whitelistedArtists[artist] = false;
        emit ArtistRemoved(artist);
    }

    // ─── Platform Fee Withdrawal ─────────────────────────────────────────

    /// @notice Withdraw accumulated platform fees from a single Project.
    ///         Uses balance delta (so pre-existing factory ETH isn't swept).
    ///         PDProject.withdraw() is a no-op when balance is zero — so
    ///         this function doesn't revert on already-swept Projects.
    function withdrawFrom(address project) external onlyAdmin {
        uint256 balanceBefore = address(this).balance;
        PDProject(project).withdraw();
        uint256 received = address(this).balance - balanceBefore;

        if (received > 0) {
            (bool success,) = platformWallet.call{value: received}("");
            if (!success) revert TransferFailed();
            emit FeesWithdrawn(project, platformWallet, received);
        }
    }

    /// @notice Paginated batch withdraw — sweeps [start, end) from the projects array.
    ///         Use this as the platform scales past the point where a full sweep
    ///         would exceed block gas. Range is clamped to array length.
    function batchWithdrawRange(uint256 start, uint256 end) external onlyAdmin {
        uint256 len = projects.length;
        if (end > len) end = len;
        if (start >= end) revert InvalidRange();

        uint256 balanceBefore = address(this).balance;

        for (uint256 i = start; i < end;) {
            // try/catch keeps this safe if a future Project ever misbehaves.
            try PDProject(projects[i]).withdraw() {} catch {}
            unchecked { ++i; }
        }

        uint256 received = address(this).balance - balanceBefore;
        if (received > 0) {
            (bool success,) = platformWallet.call{value: received}("");
            if (!success) revert TransferFailed();
            emit BatchFeesWithdrawn(platformWallet, received, end - start);
        }
    }

    /// @notice Convenience sweep of every Project. Safe up to ~30-50 Projects
    ///         before block gas becomes a concern; switch to batchWithdrawRange past that.
    function batchWithdraw() external onlyAdmin {
        uint256 balanceBefore = address(this).balance;
        uint256 len = projects.length;

        for (uint256 i; i < len;) {
            try PDProject(projects[i]).withdraw() {} catch {}
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

    // ─── Receive ─────────────────────────────────────────────────────────

    /// @notice Accept ETH from Project withdrawals.
    receive() external payable {}
}
