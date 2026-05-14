# Contract Audit — 2026-05-14 (Post-Patch Pass)

Closes the four actionable findings raised in the 2026-05-14 post-rewrite pass against `pd-contracts@main`. Independent compile-verify clean. All deployable bytecode well under the 24,576-byte mainnet contract size limit.

## Header

| | |
|---|---|
| Repository | `github.com/brendonrell/pd-contracts` |
| Branch | `main` |
| Commit | `d4b0e042d358ef8a76761da714f1dcedbadeb4cc` |
| Compiler | `solc 0.8.24` (`+commit.e11b9ed9`) |
| Optimizer | enabled, 200 runs |
| IR pipeline | `via_ir = true` |
| EVM version | `paris` |
| Scope | `src/PDFactory.sol`, `src/PDProject.sol`, `src/PaymentSplitter.sol` |

### Deployable bytecode sizes

Runtime (deployed) bytes, measured against the 24,576-byte EIP-170 mainnet limit. These are the bytes that live on-chain after deployment; the larger init-code figures are one-time, paid by the deployer at deploy.

| Contract | Runtime | Init | Margin to 24,576 |
|---|---:|---:|---:|
| `PDFactory` | 20,966 | 21,484 | 3,610 |
| `PDProject` | 12,968 | 15,094 | 11,608 |
| `PaymentSplitter` | 1,272 | 1,517 | 23,304 |

Independent compile reproduces the prior chat's sizes exactly. No compiler warnings.

---

## NA-01 — Closed

**Original finding (HIGH):** `name` and `description` flow straight into the on-chain JSON of `tokenURI` without sanitization. A single double-quote, backslash, or control byte in either string breaks the JSON forever — marketplaces fail to parse the token's metadata and the listing card disappears. `description` has no setter after deploy. Recovery surface is zero.

**Patch landmark:** belt and suspenders, applied at both ends of the data path.

Upstream gate, `src/PDFactory.sol`:
- Line 181–182 — `_assertJsonSafe(bytes(name))` and `_assertJsonSafe(bytes(description))` run before any state is written or any contract is deployed.
- Line 269–276 — `_assertJsonSafe` rejects bytes `0x00–0x1F`, `0x22` (`"`), `0x5C` (`\`), and `0x7F` (DEL). Multi-byte UTF-8 (anything `0x80` and up) passes through, so emoji and non-ASCII text are fine.
- Line 95 — new error `InvalidCharacter` surfaces a clean revert at deploy time, before the artist commits any gas to the Project deploy.

Downstream defense, `src/PDProject.sol`:
- Line 366 and 370 — `tokenURI` wraps `name()` and `description` in `_jsonEscape` before splicing them into the JSON.
- Line 391–433 — `_jsonEscape` implements RFC 8259 §7 string escaping: `\"`, `\\`, the common whitespace escapes (`\b`, `\t`, `\n`, `\f`, `\r`), and `\u00XX` for everything else under `0x20` plus DEL. UTF-8 multi-byte payload passes through.

**Verdict:** closed. The factory rejects the bad input class before deploy. The Project renders JSON-safe even if a Project deployed before this patch landed somehow held an unsafe string.

---

## NA-02 — Closed

**Original finding (HIGH):** `PaymentSplitter` captured `platformWallet` as an immutable address at construction time. If the platform's admin key was ever rotated to a new wallet, every previously-deployed Project's splitter would keep routing 2% of every secondary sale to the old (potentially compromised) wallet forever. Primary mint fees rotated cleanly; secondary did not. The compromise narrative in the spec — "only future mints are at risk" — was true for primary, materially false for secondary.

**Patch landmark:** rotation symmetry between primary and secondary, by reading the platform destination live from the factory at withdraw time instead of snapshotting it at deploy.

`src/PaymentSplitter.sol`:
- Line 26–27 — splitter stores `artist` and `factory` as immutable. The platform address is no longer stored; the splitter holds a pointer to the factory and asks the factory for the current platform wallet on demand.
- Line 40–44 — constructor now takes `(_artist, _factory)`. Zero-address check on both.
- Line 48–50 — public `platform()` view reads `IPDFactory(factory).platformWallet()` live. Any external caller (frontends, indexers, royalty tools) sees the current destination immediately after a factory-level rotation.
- Line 76–84 — `withdrawPlatform` reads `IPDFactory(factory).platformWallet()` at the moment of withdrawal and routes to that address. Both already-accumulated and not-yet-earned royalties follow rotations.

`src/PDFactory.sol`:
- Line 192 — factory passes `address(this)` to the splitter, not its current `platformWallet`. The splitter binds to the factory, never to a specific wallet.

**Cost of the indirection:** one extra cross-contract read on each platform withdraw. Negligible compared to the rotation symmetry gained.

**Verdict:** closed. A platform wallet rotation now applies identically to primary fees (already live, already rotating cleanly) and to every existing splitter's secondary royalty share. The compromise-recovery story matches the spec.

---

## NA-03 — Closed

**Original finding (MEDIUM):** the Uniswap V3 TWAP fallback wrapped the external pool read in `try / catch`, but the math that converted the pool's tick into a USD price ran inline inside the success branch. Solidity's `try / catch` only catches reverts from the external call itself, not from statements after it. If the price math (`getQuoteAtTick`) reverted on an extreme tick or overflow, the revert bubbled up past the catch with a raw math error instead of cleanly cascading to `OracleFailed`. Unlikely to fire in practice on the WETH/USDC pool, but it broke the spec's cascade contract.

**Patch landmark:** every line of math that can revert is now inside the external call boundary the `try` catches.

`src/PDProject.sol`:
- Line 310–316 — new `peekUniswapEthUsdPrice18(pool)`. External view. Performs the entire computation in one call: consult the pool for the time-weighted tick, convert that tick into a USDC-per-1-ETH quote, scale to 18 decimals. Any revert anywhere in this chain is contained to this external call.
- Line 293–301 — `_tryUniswapTwap` calls `peekUniswapEthUsdPrice18` via `this.` (the syntax that forces an external call so the try/catch boundary engages). On revert, returns 0; the cascade falls through to the final revert.
- Line 245–263 — `_getEthUsdPrice18` cascade unchanged in shape: Chainlink, one retry, Uniswap fallback, revert `OracleFailed`. Each branch surfaces 0 to the caller on failure rather than bubbling raw reverts.

**Verdict:** closed. The spec's promise — both oracle paths fail cleanly with `OracleFailed`, frontends and indexers can pattern-match the error — is now honored in code under every reachable revert path.

---

## NA-04 — No action by design

**Original finding (MEDIUM):** the storage-fee writer (an off-chain key operated by the platform) can call `setArweaveTxid` once per token. Once set, no admin and no writer can change it — the bind is permanent. A compromised writer key or a buggy writer pipeline could pin garbage Arweave txids on every minted token, leaving every collector's marketplace listing card with a broken thumbnail. Canonical art is unaffected (`animation_url` is fully on-chain HTML from SSTORE2 chunks plus the token hash; zero Arweave dependency for the actual artwork). Discovery surface — the `image` field marketplaces display — is the part exposed.

**Rationale for no contract change:** the immutability spec is load-bearing. Every contract is immutable, no admin path reaches into deployed Projects, write-once means write-once. Adding an `emergencyClearArweaveTxid` would carve out an admin-controlled override on a per-token field, which is exactly the surface C-02 was about removing in the rewrite. The trade is a known one: discovery resilience versus the integrity of the "no admin reach into Projects" promise. The spec keeps the promise.

**Mitigation lives operationally, not in the contract:**

- The writer pipeline round-trip-verifies each Arweave manifest URL returns the expected MIME and bytes before broadcasting `setArweaveTxid`.
- The writer key is operated as a hot key with a documented rotation procedure (`PDFactory.setStorageFeeWriter`). Rotation does not retroactively clear bad pins, but it stops the bleeding after the next mint.
- The canonical art rendering surface (`animation_url`) remains fully on-chain with no Arweave dependency. Even a worst-case writer compromise cannot affect what the artwork actually looks like — only the preview thumbnail shown on marketplace listing cards.

**Verdict:** no action. Operational discipline owns this finding; the contract's immutability is preserved.

---

## NA-05 — Closed

**Original finding (LOW):** `mint(uint256 quantity)` was bounded only by the Project's `maxSupply` and by the gas limit. A single transaction at drop time could mint the entire supply, capturing the full Project for one buyer. Economically permissible — full price plus storage fee per token — but it removed the grief floor and undermined the "fair drop" expectation collectors bring to a launch.

**Patch landmark:** a hard per-transaction cap, set to 22 to match the Kiki genesis edition price point that's already shaping the platform's launch narrative.

`src/PDProject.sol`:
- Line 56 — `MAX_MINT_PER_TX = 22` as a `public constant`. Exposed for frontends to read directly.
- Line 112 — new error `QuantityExceedsTxCap`.
- Line 175 — first check inside `mint(quantity)`: if `quantity > MAX_MINT_PER_TX`, revert. Sits ahead of the supply check and the oracle read, so a busted mint costs the caller almost nothing.

The Project-level supply cap remains the actual scarcity bound. The transaction cap is the grief floor — no single transaction can sweep more than 22 Outputs at once, so a contested drop spreads across multiple senders and multiple blocks.

**Verdict:** closed. A contested drop now requires either multiple wallets or multiple transactions per wallet.

---

## NA-06 / NA-07 — Informational, no change

NA-06 (CEI ordering of the push trio) and NA-07 (the `MintFeeDistributed` event using `tokenId` as the first-of-batch anchor with cumulative shares) were observations, not findings requiring action. The post-patch code preserves both behaviors as documented. Indexer implementations should continue to treat `MintFeeDistributed.artistShare` / `platformShare` / `storageShare` as batch cumulative, not per-token.

---

## Result

All four actionable findings from the 2026-05-14 post-rewrite pass are closed in code on `main` at `d4b0e042d358ef8a76761da714f1dcedbadeb4cc`. NA-04 stays no-action by design — the contract's immutability story is the load-bearing property, and writer-pipeline discipline is the operational mitigation. Compile-verify reproduces the prior chat's deployable bytecode sizes exactly under `solc 0.8.24`, optimizer 200, `via_ir = true`, `evmVersion = paris`.

The mainnet gate this audit was the last step of is now clear on the contract side. Remaining gates are deployment-mechanics, not code.
