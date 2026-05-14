// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal interface used by PaymentSplitter to read the platform's
///      current royalty receiver live, so platform-wallet rotations apply
///      to accumulated AND future royalties identically (matches the
///      primary-fee path which also reads platformWallet() live at mint).
interface IPDFactory {
    function platformWallet() external view returns (address);
}

/// @title PaymentSplitter
/// @notice Minimal immutable 2-way royalty splitter for PD Projects.
///         Deployed once per Project by PDFactory. Receives secondary royalties
///         via EIP-2981 and splits them 60/40 (artist/platform).
///         This maps to the overall 5% royalty as 3% artist / 2% platform.
///         No admin. No upgrades. Permanent.
///
///         The platform wallet is looked up live from the factory at withdraw
///         time rather than snapshotted at deploy. This preserves rotation
///         symmetry with the primary-fee path: if the platform wallet rotates,
///         both accumulated and future royalty shares flow to the new wallet.
///         The artist address is immutable per Project (artist identity is the
///         Project; the wallet is operational).
contract PaymentSplitter {
    address public immutable artist;
    address public immutable factory;

    uint256 public artistBalance;
    uint256 public platformBalance;

    event RoyaltyReceived(uint256 amount, uint256 artistShare, uint256 platformShare);
    event ArtistWithdrawal(address indexed to, uint256 amount);
    event PlatformWithdrawal(address indexed to, uint256 amount);

    error ZeroAddress();
    error NothingToWithdraw();
    error TransferFailed();

    constructor(address _artist, address _factory) {
        if (_artist == address(0) || _factory == address(0)) revert ZeroAddress();
        artist = _artist;
        factory = _factory;
    }

    /// @notice Current platform royalty receiver — looked up live from the
    ///         factory. Rotates instantly with `factory.setPlatformWallet`.
    function platform() public view returns (address) {
        return IPDFactory(factory).platformWallet();
    }

    /// @notice Accept ETH (from marketplace royalty forwards) and split 60/40.
    ///         60% of 5% total royalty = 3% to artist.
    ///         40% of 5% total royalty = 2% to platform.
    receive() external payable {
        uint256 artistShare = (msg.value * 60) / 100;
        uint256 platformShare = msg.value - artistShare; // uses delta to avoid rounding dust
        artistBalance += artistShare;
        platformBalance += platformShare;
        emit RoyaltyReceived(msg.value, artistShare, platformShare);
    }

    /// @notice Artist withdraws their accumulated share. Anyone can trigger — funds only flow to the immutable artist address.
    function withdrawArtist() external {
        uint256 amount = artistBalance;
        if (amount == 0) revert NothingToWithdraw();
        artistBalance = 0;
        emit ArtistWithdrawal(artist, amount);
        (bool success,) = artist.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /// @notice Platform withdraws their accumulated share. Destination is the
    ///         factory's current `platformWallet()`. Anyone can trigger — funds
    ///         only flow to the factory-controlled platform wallet.
    function withdrawPlatform() external {
        uint256 amount = platformBalance;
        if (amount == 0) revert NothingToWithdraw();
        platformBalance = 0;
        address dest = IPDFactory(factory).platformWallet();
        emit PlatformWithdrawal(dest, amount);
        (bool success,) = dest.call{value: amount}("");
        if (!success) revert TransferFailed();
    }
}
