// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";

/// @title MockChainlinkAggregator
/// @notice Test double for the Chainlink ETH/USD feed.
///         Decimals fixed at 8 to mirror mainnet ETH/USD (0x5f4e…8419).
///         `setAnswer` updates both the price and the updatedAt timestamp.
///         `setUpdatedAt` lets a test simulate staleness while keeping the price.
///         `setShouldRevert(true)` makes `latestRoundData` revert outright,
///         exercising the try/catch fallback path in PDProject._tryChainlink.
contract MockChainlinkAggregator is IChainlinkAggregator {
    int256 internal _answer;
    uint256 internal _updatedAt;
    uint8 internal constant DECIMALS = 8;
    bool internal _shouldRevert;

    constructor(int256 initialAnswer, uint256 initialUpdatedAt) {
        _answer = initialAnswer;
        _updatedAt = initialUpdatedAt;
    }

    function setAnswer(int256 a) external {
        _answer = a;
        _updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 ts) external {
        _updatedAt = ts;
    }

    function setShouldRevert(bool v) external {
        _shouldRevert = v;
    }

    function decimals() external pure override returns (uint8) {
        return DECIMALS;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        if (_shouldRevert) revert("MockChainlink: forced revert");
        return (uint80(1), _answer, _updatedAt, _updatedAt, uint80(1));
    }
}

/// @title IUniswapV3PoolDerivedState
/// @notice Local copy of the observe-only surface PDProject's oracle uses.
///         Mirrored verbatim from src/libraries/UniswapV3OracleLibrary.sol so
///         the mock's storage layout doesn't depend on the library file.
interface IUniswapV3PoolDerivedState {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title MockUniswapV3Pool
/// @notice Test double for the WETH/USDC 0.05% V3 pool. Returns deterministic
///         tickCumulatives so the OracleLibrary.consult call yields a known
///         arithmetic-mean tick.
///
///         Configure via `setTick(int24)` — the mock derives tickCumulatives
///         such that `consult(pool, 1800)` returns exactly that tick:
///           tickCumulatives[0] = 0
///           tickCumulatives[1] = tick * 1800
///
///         `setShouldRevert(true)` makes `observe` revert, exercising the
///         try/catch fallback path in PDProject._tryUniswapTwap via the
///         `peekTwapTick` external wrapper.
contract MockUniswapV3Pool is IUniswapV3PoolDerivedState {
    int24 internal _tick;
    bool internal _shouldRevert;

    /// @dev Window OracleLibrary.consult is hard-coded to in PDProject.
    uint32 internal constant TWAP_WINDOW = 1800;

    constructor(int24 initialTick) {
        _tick = initialTick;
    }

    function setTick(int24 t) external {
        _tick = t;
    }

    function setShouldRevert(bool v) external {
        _shouldRevert = v;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (_shouldRevert) revert("MockUniswap: forced revert");

        uint256 n = secondsAgos.length;
        tickCumulatives = new int56[](n);
        secondsPerLiquidityCumulativeX128s = new uint160[](n);

        // Library calls observe([TWAP_WINDOW, 0]). Convention:
        //   tickCumulatives[0] = cumulative at (now - TWAP_WINDOW)
        //   tickCumulatives[1] = cumulative at now
        // We want (cum[1] - cum[0]) / TWAP_WINDOW == _tick.
        // So set cum[i] proportional to (TWAP_WINDOW - secondsAgos[i]) * _tick.
        for (uint256 i = 0; i < n; i++) {
            uint32 sa = secondsAgos[i];
            int256 elapsed = int256(uint256(TWAP_WINDOW)) - int256(uint256(sa));
            tickCumulatives[i] = int56(elapsed * int256(_tick));
            secondsPerLiquidityCumulativeX128s[i] = 0;
        }
    }
}

/// @title RevertingReceiver
/// @notice Always reverts on plain ETH transfers. Used to assert that a mint
///         atomically rolls back when a fee destination wallet cannot accept ETH.
contract RevertingReceiver {
    receive() external payable {
        revert("RevertingReceiver: blocked");
    }
}

/// @title AcceptingReceiver
/// @notice Plain ETH sink with a non-reverting receive(). Used where a test
///         needs an EOA-equivalent destination but wants to assert balance
///         deltas on a contract rather than a vm.makeAddr() EOA.
contract AcceptingReceiver {
    receive() external payable {}
}

/// @title MockWETH / MockUSDC
/// @notice Address-only token placeholders. The oracle path only reads token
///         addresses (for the lt() comparison inside getQuoteAtTick) — no
///         ERC-20 calls are made. So an empty contract address is sufficient.
contract MockWETH {}
contract MockUSDC {}
