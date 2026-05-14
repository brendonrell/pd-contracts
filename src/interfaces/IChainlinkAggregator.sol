// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IChainlinkAggregator
/// @notice Minimal AggregatorV3Interface — function-for-function compatible with
///         the official chainlink/contracts package. Vendored inline so the
///         deployed contracts are fully self-contained for Etherscan Standard
///         JSON Input verification.
///
///         Reference: chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol
interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}
