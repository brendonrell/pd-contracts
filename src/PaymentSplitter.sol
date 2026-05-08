// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PaymentSplitter
/// @notice Minimal immutable 2-way royalty splitter for PD collections.
///         Deployed once per collection by PDFactory. Receives secondary royalties
///         via EIP-2981 and splits them 60/40 (artist/platform).
///         This maps to the overall 5% royalty as 3% artist / 2% platform.
///         No admin. No upgrades. Permanent.
///
///         Unchanged from 4.6 draft — contract was correct as written.
contract PaymentSplitter {
    address public immutable artist;
    address public immutable platform;

    uint256 public artistBalance;
    uint256 public platformBalance;

    event RoyaltyReceived(uint256 amount, uint256 artistShare, uint256 platformShare);
    event ArtistWithdrawal(address indexed to, uint256 amount);
    event PlatformWithdrawal(address indexed to, uint256 amount);

    error ZeroAddress();
    error NothingToWithdraw();
    error TransferFailed();

    constructor(address _artist, address _platform) {
        if (_artist == address(0) || _platform == address(0)) revert ZeroAddress();
        artist = _artist;
        platform = _platform;
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

    /// @notice Platform withdraws their accumulated share. Same pattern.
    function withdrawPlatform() external {
        uint256 amount = platformBalance;
        if (amount == 0) revert NothingToWithdraw();
        platformBalance = 0;
        emit PlatformWithdrawal(platform, amount);
        (bool success,) = platform.call{value: amount}("");
        if (!success) revert TransferFailed();
    }
}
