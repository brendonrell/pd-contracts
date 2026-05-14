# PD Contracts

Smart contracts for [Price Discussion](https://pricediscussion.com), a curated generative art platform on Ethereum mainnet.

## Architecture

| Contract | Role |
|---|---|
| `PDFactory.sol` | Deployer and registry. Holds the artist whitelist, enforces the 60-day cooldown between drops, and stores the oracle wiring and platform fee wallets. |
| `PDProject.sol` | One per artist drop. Vanilla ERC-721 with the generative script stored fully on-chain via SSTORE2. Token hashes are deterministic and seeded with `blockhash + tokenId + minter`. Fully on-chain `tokenURI`. |
| `PDStickers.sol` | The platform's sticker shop. ERC-1155 with on-chain SVG metadata. Primary sales are sheets only — buyers receive every sticker in the sheet via `_mintBatch`. |
| `PaymentSplitter.sol` | One per Project. Receives EIP-2981 secondary royalties and splits them 60/40 between artist and platform. |

Every contract is immutable. No proxies, no pause switch, no admin path into a deployed Project.

### Economics

Every mint distributes funds atomically in three pushes within the mint transaction itself:

- 95% of mint price → artist
- 5% of mint price → platform wallet
- $2 USD-equivalent storage fee → storage-fee wallet

`PDProject` holds zero balance between transactions. If any destination wallet reverts on receive, the entire mint reverts atomically — no funds stuck, no partial state.

Secondary royalties are 5% total via EIP-2981, split 3% artist / 2% platform via the per-Project `PaymentSplitter` (pull pattern retained because the senders are arbitrary marketplaces).

Hard caps: 10,000 Outputs per Project, 64 stickers per sheet, 60 days between Project deploys per artist.

### Storage fee oracle

The $2 storage fee is USD-pegged via an on-chain cascade:

1. Chainlink ETH/USD — primary, 1-hour staleness window.
2. Retry once if stale.
3. Uniswap V3 WETH/USDC 0.05% pool, 30-minute arithmetic-mean tick TWAP — fallback.
4. Both fail → mint reverts.

The Chainlink interface and a 0.8.x port of the Uniswap V3 `OracleLibrary` are vendored inline under `src/interfaces/` and `src/libraries/` so the deployed bytecode is self-contained for Etherscan Standard JSON Input verification.

## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install vectorized/solady --no-commit
forge install foundry-rs/forge-std --no-commit
forge build
forge test
```

Built against `solc 0.8.24` with `via_ir = true` — `PDFactory` and `PDProject` hit stack-too-deep without it.

## Audit

Not audited. Do not deploy to mainnet without one.

## Layout

```
src/
  PDFactory.sol
  PDProject.sol
  PDStickers.sol
  PaymentSplitter.sol
  interfaces/
    IChainlinkAggregator.sol
  libraries/
    UniswapV3OracleLibrary.sol
test/
  PDFactory.t.sol
  PDProject.t.sol
  PDStickers.t.sol
  PaymentSplitter.t.sol
  mocks/
    Mocks.sol
  integration/
    OracleFallback.t.sol
    ArweaveTxidWrite.t.sol
    PushPayments.t.sol
foundry.toml
```

## License

MIT.
