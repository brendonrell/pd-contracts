# PD Contracts

Smart contracts for [Price Discussion](https://pricediscussion.com), a curated generative art platform on Ethereum mainnet.

## Architecture

| Contract | Role |
|---|---|
| `PDFactory.sol` | Deployer and registry. Holds the artist whitelist, enforces the 60-day cooldown between drops, and sweeps platform fees. |
| `PDCollection.sol` | One per artist drop. Vanilla ERC-721 with the generative script stored fully on-chain via SSTORE2. Token hashes are deterministic and seeded with `blockhash + tokenId + minter`. |
| `PDStickers.sol` | The platform's sticker shop. ERC-1155 with on-chain SVG metadata. Primary sales are sheets only — buyers receive every sticker in the sheet via `_mintBatch`. |
| `PaymentSplitter.sol` | One per collection. Receives EIP-2981 secondary royalties and splits them 60/40 between artist and platform. |

Every contract is immutable. No proxies, no pause switch, no admin path into a deployed collection.

### Economics

- **Primary mint:** 95% to the artist (paid directly at mint time), 5% accrued for the platform to sweep.
- **Secondary royalties:** 5% total, split 3% artist / 2% platform via the per-collection `PaymentSplitter`.
- **Hard caps:** 10,000 editions per collection, 64 stickers per sheet.
- **Cooldown:** 60 days between collection deploys per artist.

## Setup

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install vectorized/solady --no-commit
forge install foundry-rs/forge-std --no-commit
forge build
forge test
```

`foundry.toml` ships with `via_ir = true` — required because `PDFactory` and `PDCollection` hit stack-too-deep without it. Don't toggle it off.

## Status

Compiled clean against `solc 0.8.24` with `via_ir = true`. Tests are first-pass: ~60 cases covering happy paths, access control, cooldown, paginated withdrawals, sheet purchasing, and EIP-2981 royalty math. Not yet exhaustive — multi-collection integration scenarios and cross-collection cooldown cases are tracked separately.

Deploy scripts (`DeployFactory`, `DeployStickers`, `WhitelistArtist`) are not in this repo yet.

A human audit is required before mainnet.

## Layout

```
src/
  PDFactory.sol
  PDCollection.sol
  PDStickers.sol
  PaymentSplitter.sol
test/
  PDFactory.t.sol
  PDCollection.t.sol
  PDStickers.t.sol
  PaymentSplitter.t.sol
foundry.toml
```

## License

MIT.
