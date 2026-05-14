# Cross-Stack Alignment Audit — Pass 1 of 2

First of two backend-alignment passes before Sepolia deploy. Looks for drift between the contract code on the one hand and the API, indexer touchpoints, frontend code, and docs on the other. Pass 2 will cover URL architecture, Supabase RLS, storage principles, and domain references.

## Header

| | |
|---|---|
| Audit date | 2026-05-14 |
| `pd-contracts` SHA (code under audit) | `d4b0e042d358ef8a76761da714f1dcedbadeb4cc` |
| `pd-contracts` SHA (HEAD; adds this report's predecessor only) | `cd82b98d909406071e80a5c64848ddfcef7679d2` |
| `PriceOS` SHA (dev branch) | `4a15b96be1731eecd4a518659749b45d2c4f9aad` |
| Scope (in) | `src/PDFactory.sol`, `src/PDProject.sol`, `src/PaymentSplitter.sol` and all of `PriceOS/dev`: API routes, Supabase types, frontend components, docs, README files |
| Scope (out) | `PDStickers.sol` (deferred), the indexer repo (not in either checkout — gaps flagged where they would have caught something here) |
| Findings | 2 P0, 9 P1, 5 P2 |

**P0 = blocks Sepolia deploy.** Wrong numbers a user would see and act on, or wrong cross-stack assumptions that would cause a transaction to revert.
**P1 = should fix before mainnet.** Cosmetic or naming drift that's user-visible, or correct values that aren't sourced from the contract and could drift later.
**P2 = nice-to-have.** Internal-only naming, dead-spec references, ergonomic cleanup.

---

## Job 1 — Nomenclature

Locked vocabulary: **Project, Output, Artwork, Token, Collection, Starred, Edition.** Banned synonyms per the lock: wishlist, drop, NFT, mint pass, gallery, piece, work, item, listing, asset.

### P1

**1.1 — `wishlist` is a banned synonym but exists as a first-class concept**

- Two Supabase tables, identical shape: `stars` and `wishlist` (`PriceOS/lib/supabase.ts` lines 66–78 and 73–78, plus the `Database` type at lines 118–129).
- Two profile sub-routes, side by side: `/{handle}/starred` and `/{handle}/wishlist` (`PriceOS/README.md` lines 29 and 50; `PriceOS/app/[slug]/wishlist/page.tsx`).
- Frontend treats them as different things: comments in `components/profile/ProfilePageBody.tsx` describe wishlist as "purchase intent list," distinct from Starred. UI has both pills (lines 90–93, 296, 307).

This isn't accidental drift — the codebase has built wishlist as a deliberate second concept (purchase intent), separate from Starred (personal favourite). But the locked vocabulary explicitly lists wishlist as banned. One of those two has to change.

**Recommended resolution:** CEO decision — either rename the purchase-intent concept to a non-banned word and remove `wishlist` everywhere (table, route, UI, comments), or update the locked vocabulary to permit it as a distinct second concept.

**1.2 — `Gallery` is on screen-readers**

`aria-label="Gallery"` ships on the output grid in two places:
- `components/project/ProjectPageBody.tsx` line 1012
- `components/profile/ProfilePageBody.tsx` line 325

Banned word, and these are the labels a screen reader announces to users.

**Recommended resolution:** rename the aria-label to `"Outputs"` (or another locked term that fits) in both files.

**1.3 — `drops` in the contract README**

`pd-contracts/README.md`:
- Line 9: "enforces the 60-day cooldown between drops"
- Line 28: "60 days between Project deploys per artist" (this one's fine — used "Project deploys")

Banned word, in the public-facing contract docs. The contract code itself uses "Project" throughout; the README is the only place that slipped.

**Recommended resolution:** change line 9 "between drops" to "between Project deploys" to match line 28.

**1.4 — `listing` is everywhere in user-facing copy**

Banned word, but it's the standard secondary-market term ("X listed token Y for Z ETH"). No replacement word is specified in the lock. Hits:
- `lib/data/tapeEvents.ts` lines 66, 72, 74, 81, 86, 91, 97 — verbs like `"new listing"`, `"cancelled listing"`, `"listed"`
- `lib/state/ValuePromptContext.tsx` lines 158–159 — modal copy: `"Every listing shows a bracketed delta..."`
- `components/project/ProjectPageBody.tsx` line 512 — code comment: `"listing-only floor"`

**Recommended resolution:** CEO decision — either lift the ban on `listing` (it's the universal secondary-market term, and the lock doesn't define a replacement), or define a replacement word now so a single rename sweep can land in pass 2.

**1.5 — `Kiki genesis drop` in calendar data**

`lib/calendar/data.ts` line 12:
```
'2026-04-03': [{ time: '10:00', title: 'Kiki genesis drop (anniversary)' }],
```

User-visible calendar event title. Banned word as a noun for a project launch.

**Recommended resolution:** rename to `"Kiki genesis (anniversary)"` or `"Kiki launch (anniversary)"`.

### P2

**1.6 — `#gallery` as a DOM ID and CSS hook**

Banned word, but used internally as a CSS / DOM hook (not user-visible). 32+ hits in `app/globals.css`, plus matching `id="gallery"` and `document.getElementById('gallery')` in:
- `components/project/ProjectPageBody.tsx` (lines 367, 384, 386, 637, 1011)
- `components/profile/ProfilePageBody.tsx` line 324
- `components/artwork/ArtworkPageBody.tsx` line 315
- `lib/engines/budgetEngine.ts` lines 298–324

This is the implementation-level twin of finding 1.2. Internal-only, but if the lock applies to all references including internal ones, it needs a global rename.

**Recommended resolution:** rename `#gallery` → `#outputs-grid` (or equivalent) in CSS and TSX as a single sweep; nothing user-visible changes.

**1.7 — `coll` shorthand in code**

- `lib/data/tapeEvents.ts` line 38 — tape-event field name `coll: string` ("collection")
- `app/api/search/route.ts` line 42 — variable name `colRes` for what queries the `projects` table

Lock says "Project," not "Collection." `coll` short for Collection is internal naming drift.

**Recommended resolution:** rename `coll` → `project` in `TapeFeedItem`, and `colRes` → `projectRes` in `search/route.ts`.

**1.8 — `piece` in code comments**

Idiom use in comments (`"Single Output tile in the project gallery"`, `"deterministic per id so each row reads as a distinct piece"`). Not user-visible; cosmetic.

**Recommended resolution:** clean up next time the file is touched; don't sweep just for this.

### NA — confirmed not drift

- **`stars` table is a deliberate carve-out.** The locked vocabulary's "Starred" maps cleanly to `stars` (table) and `/starred` (route). This pair is consistent. The drift in finding 1.1 is on the wishlist side only.

---

## Job 2 — Contract events vs API and indexer surface

The contract emits a fixed set of events. The API exposes its own event taxonomy. They aren't a 1-to-1 mapping (the indexer is the translation layer), but every shape on the API side needs to come from somewhere on the contract side, and a few of the contract's quirks need a consumer that understands them.

### P0

**2.1 — The API's `cooldown_until` field is wrong**

Two routes calculate the artist cooldown end-time from "mint-end + 60 days." The contract doesn't work that way.

- `PriceOS/app/api/project/[slug]/route.ts` line 47 — comment: `"cooldown begins on mint-end"`
- `PriceOS/app/api/artist/[address]/route.ts` lines 1–5 — header comment: `"60-day cooldown is computed from the most recent project's mint-end timestamp + 60 days"` and references an invented `mint_ended_at` column.

**What the contract actually does:** `PDFactory.sol` line 207 sets `lastProjectTimestamp[artist] = block.timestamp;` at the moment `createProject` is called. The cooldown clock starts on project creation, not on mint completion. The contract has no concept of "mint-end" — a primary mint can stay open indefinitely.

**Why it matters:** an artist looks at the frontend, sees "you can launch your next Project in 14 days," waits 14 days, clicks create — and gets a `CooldownActive` revert because the contract is counting from a different starting point. The frontend is showing a number that doesn't reflect what the contract will accept.

**Recommended resolution:** delete the `mint-end` framing in both routes. Compute `cooldown_until = project_created_at + 60 days` using the on-chain `lastProjectTimestamp(artist)` value. The contract already exposes `cooldownRemaining(artist)` and `canCreateProject(artist)` view functions — the API should source from those, not from an invented indexer column.

### P1

**2.2 — `MintFeeDistributed` cumulative-vs-per-token trap (informational; PriceOS doesn't consume it yet)**

`PDProject.sol` line 207 emits `MintFeeDistributed(firstTokenId, artistShare, platformShare, storageShare)` once per mint transaction. The `tokenId` is the **first** token of the batch — not one per token. The three share fields are **batch totals** — not per-token amounts.

Grep across PriceOS shows **zero consumers** of this event today. So the trap doesn't bite here. But:
- The post-patch audit (`pd-contracts/audit/2026-05-14-post-patch-pass.md` finding NA-07) flags this as the easy place to mis-index.
- The indexer repo (`PriceOS-indexer`, not pulled in this audit's scope) is where this event will land first.

**Recommended resolution:** add a note to the API spec at `PriceOS/docs/api-spec.md` documenting `MintFeeDistributed` semantics for the eventual indexer team, and surface the indexer audit as a hard prerequisite before any production fee-attribution surface ships.

**2.3 — Arweave preview-image format is undocumented downstream**

`PDProject.sol` lines 444 and 230–239 set the write-once preview URL to `ar://<txid>/preview.webp`. Filename is hardcoded as `preview.webp`. Zero consumers in PriceOS today (grep for `ar://`, `setArweaveTxid`, `arweaveManifest`, `tokenArweave` all return nothing).

When PriceOS starts rendering token previews, the marketplace card needs to know:
- The contract sets the URL exactly once (write-once). It will never change after the writer pipeline pins it.
- The filename component is always `/preview.webp`.
- Until set, the contract returns an on-chain SVG placeholder reading "PRESERVING PREVIEW" — the frontend should show this as a known state, not as a broken image.

**Recommended resolution:** when the preview-rendering surface ships, lift these three facts into a comment block at the consumer (likely `components/OutputPreview.tsx`) so they don't get rediscovered as bugs.

**2.4 — Storage-fee surface (`currentStorageFeeWei`) has no consumer**

`PDProject.sol` line 320 exposes `currentStorageFeeWei()` so the mint UI can compute exact `msg.value` before sending. Zero consumers in PriceOS today.

This is fine right now (mint UI hasn't shipped), but blocks Sepolia mint smoke-testing — there's nothing to call to find out what to send.

**Recommended resolution:** before mint UI ships, wire `currentStorageFeeWei()` into the mint quote so the UI shows `mintPrice + currentStorageFeeWei` per token. Inadequate `msg.value` reverts with `IncorrectPayment`.

**2.5 — `UserProfileResponse` shape disagrees with itself**

Cross-stack mismatch inside PriceOS itself (no contract involvement, but it'll cause client confusion downstream):
- Spec at `docs/api-spec.md` lines 64–72: lists `display_name, bio, avatar_url`
- Code at `app/api/user/[address]/route.ts` lines 9–12: returns `UserRow` which has `handle, price_sprite, account_level`

Neither file knows the other one says different things. Whichever is the truth, the other one's stale.

**Recommended resolution:** CEO decision — pick spec or code as truth, rewrite the other.

### P2

**2.6 — The API's `EventType` is not a contract event**

`PriceOS/lib/supabase.ts` line 40: `type EventType = 'MINT' | 'LIST' | 'SALE' | 'XFER'`.

These are indexer abstractions, not contract event names. The contract emits `Minted`, `MintFeeDistributed`, `ArweaveTxidSet`, plus 7 factory events and 3 splitter events. There's no `LIST` or `SALE` on chain — those come from marketplace contracts the indexer monitors separately.

This isn't drift per se, but the API spec doesn't document the translation. A reader of `api-spec.md` would assume `MINT` is one-for-one with the `Minted` event, when actually it's the indexer's roll-up.

**Recommended resolution:** add a one-paragraph "Event taxonomy" section to `api-spec.md` mapping the four API event types to their on-chain (or marketplace) sources.

**2.7 — `NotificationType` includes `OFFER`, never sourced**

`lib/supabase.ts` line 23–29 includes `'OFFER'` in `NotificationType`. No corresponding `EventType` (which only has the four MINT/LIST/SALE/XFER). Offers come from marketplace-specific contracts (Reservoir, Seaport, OpenSea offers) — and the API spec doesn't document where `OFFER` notifications will come from.

**Recommended resolution:** document the offer source in `api-spec.md`, or remove `'OFFER'` from `NotificationType` until the offer-tracking surface is designed.

---

## Job 3 — Economics across the stack

Contract truth, restated in plain numbers:
- **Primary mint:** 95% to artist, 5% to platform wallet. Constants `ARTIST_BPS=9500`, `PLATFORM_BPS=500`, `BPS_DENOM=10000`.
- **Secondary royalty:** 5% total via EIP-2981 (`ROYALTY_BPS=500`). Split 60/40 inside `PaymentSplitter` → 3% to artist, 2% to platform.
- **Storage fee:** $2 USD-equivalent per mint, paid in ETH (`STORAGE_FEE_USD=2`). Oracle: Chainlink ETH/USD (1-hour staleness window), retry once, fall back to Uniswap V3 30-min TWAP, revert.

### P0

**3.1 — Calc Sheet under-quotes seller take-home by 3 percentage points**

`components/CalcSheet.tsx` is the "what do I net if I sell?" calculator for secondary sales. It deducts:
- Line 43: `CALC_PLATFORM_FEE_PCT = 0.05` — labelled `"Platform (5%)"` (line 295)
- Line 44: `CALC_ROYALTY_PCT = 0.03` — labelled `"Royalty (3%)"` (line 303)
- Gas estimate

Total fee deduction: **8%** of sale price.

**Contract reality on a secondary sale:**
- EIP-2981 directs 5% of the sale to `PaymentSplitter`. That's it. The 5% is the whole royalty.
- Inside `PaymentSplitter`, that 5% gets split 60/40 (3% to artist, 2% to platform). But that split happens **downstream of the seller** — the seller never sees it. The seller just loses 5% to the royalty.
- The "Platform (5%)" line in Calc is double-counting: it's adding a "5% to platform" deduction on top of the royalty, but the platform's 2% already comes out of the 5% royalty.

**Why it matters:** Calc tells a user selling a token for 1 ETH that they'll net 0.92 ETH. The reality is they'll net 0.95 ETH. Users will price three percentage points too low because their calculator told them to. This is the highest-leverage P0 — every seller using Calc gets bad math.

**Recommended resolution:** rewrite Calc's deduction model to one line: `"Royalty (5%)"` at `0.05` of sale price. Delete `CALC_PLATFORM_FEE_PCT` entirely. The 3%/2% internal split is a backend concern; it shouldn't surface on the seller's quote.

### P1

**3.2 — Cart's fee model has the same bug**

`lib/state/CartContext.tsx`:
- Line 25: `"Fees model: 8% on subtotal (5% platform + 3% royalty) + flat"`
- Line 46: `export const CART_FEE_RATE = 0.08;`

Same structural error as 3.1, but in the bulk-buy Cart panel. If this fee surface ever quotes a buyer's total, it'll over-quote by 3 percentage points (the cart bills the buyer for the platform's 2% twice — once as part of the royalty, once as a separate 5% line).

Also: for the primary mint case (buying directly from the contract), the fee is just `mintPrice + storageFeeWei`. There's no separate royalty on primary. The Cart's model conflates secondary and primary.

**Recommended resolution:** decide what Cart actually quotes — is it for primary mint purchases, secondary buys, or both? Then model each case correctly:
- Primary: `mintPrice + storageFeeWei` per token. No royalty.
- Secondary: `salePrice` per token. The 5% royalty is paid by the seller, not the buyer.

**3.3 — Calc and Cart hardcode percentages that have on-chain constants**

The numbers in `CalcSheet.tsx` (after 3.1 is fixed) and `CartContext.tsx` (after 3.2 is fixed) should still reference contract constants, not bare literals. The contract is immutable, so the values can't drift — but a future engineer who changes one and not the other will introduce drift.

**Recommended resolution:** add a `lib/economics.ts` file that exports `PRIMARY_PLATFORM_BPS = 500`, `SECONDARY_ROYALTY_BPS = 500`, etc., with a comment naming the source constant in `PDProject.sol`. All UI math reads from there.

**3.4 — README duplicates contract values without sourcing**

`pd-contracts/README.md` lines 20–28:
- "95% of mint price → artist"
- "5% of mint price → platform wallet"
- "$2 USD-equivalent storage fee → storage-fee wallet"
- "5% total via EIP-2981, split 3% artist / 2% platform"
- "Hard caps: 10,000 Outputs per Project, 64 stickers per sheet, 60 days between Project deploys per artist"

Every number matches the contract — none of them are wrong. But they're freestanding text; nothing prevents someone from editing the contract constant and forgetting the README, or vice versa.

**Recommended resolution:** add a single-line cross-reference in the README economics section: `"(constants: PDProject.ARTIST_BPS / PLATFORM_BPS / STORAGE_FEE_USD / ROYALTY_BPS, PDFactory.MAX_SUPPLY_CAP / COOLDOWN_PERIOD)"`.

### P2

**3.5 — Gas route hardcodes the Chainlink aggregator address**

`PriceOS/app/api/gas/route.ts` line 43: `CHAINLINK_ETHUSD_AGGREGATOR = '0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419'`.

Matches the address in `PDFactory.sol` line 37's comment exactly. So they're already aligned. But the gas route's value is a literal, not sourced from the factory's `chainlinkFeed()` view. Future testnet/mainnet drift (using a different feed on Sepolia than mainnet) would silently break the gas-USD conversion before anyone noticed.

**Recommended resolution:** when the factory is deployed, switch the gas route to read `chainlinkFeed()` via the factory address. Until then, leave the literal but add a comment cross-referencing `PDFactory.chainlinkFeed`.

---

## Job 4 — Caps and invariants

Contract truth:
- `MAX_SUPPLY_CAP = 10_000` (PDFactory line 33)
- `MAX_MINT_PER_TX = 22` (PDProject line 56)
- `COOLDOWN_PERIOD = 60 days` (PDFactory line 30)
- Token IDs start at 1, strictly increasing.
- Kiki genesis is platform narrative: 2,222 editions at ~$22. Not contract-enforced.

### P1

**4.1 — Nothing in PriceOS surfaces or enforces the 22-per-transaction mint cap**

Grep for `22` in mint-flow context: zero hits. The mint UI hasn't shipped yet, so this is a forward-looking finding — but without a quantity cap in the input field, a buyer can submit a mint for 23+ and get a `QuantityExceedsTxCap` revert with no warning.

**Recommended resolution:** when mint UI ships, hard-cap the quantity input at 22 and source the value from `PDProject.MAX_MINT_PER_TX()` so the cap can't drift. Add a "max 22 per transaction" note in the mint flow's helper text.

**4.2 — Nothing in PriceOS surfaces the 10,000 per-Project supply cap**

Grep for `10_000`, `10000`, `10,000` in supply-cap context: zero hits. Again forward-looking (project-creation UI hasn't shipped), but when it does, the form needs to validate `maxSupply <= 10_000` before sending the transaction or the user gets a `MaxSupplyExceeded` revert.

**Recommended resolution:** when project-creation UI ships, source the cap from `PDFactory.MAX_SUPPLY_CAP()` and validate the form input client-side before submission.

### P2

**4.3 — Mock data hardcodes Kiki's 2,222 in five files**

- `app/api/project/[slug]/route.ts` line 43: `max_supply: 2222`
- `app/api/project/[slug]/outputs/route.ts` line 50: `MOCK_TOTAL = 2222`
- `app/api/project/[slug]/feed/route.ts` line 53: `((i * 13) % 2222) + 1`
- `app/api/artist/[address]/route.ts` line 63: `max_supply: 2222`
- `app/api/feed/route.ts` line 72: `((i * 11) % 2222) + 1`

All are mock data slated for indexer replacement. Currently fine — flagged so the indexer swap doesn't accidentally inherit the literal. Real `maxSupply` is per-Project and comes from the chain.

**Recommended resolution:** no action now; track for the indexer-swap pass.

**4.4 — `KikiTraits` is baked into general output interface types**

- `app/api/output/[id]/route.ts` lines 11–16
- `app/api/project/[slug]/outputs/route.ts` lines 10–15

Both define `KikiTraits = { Palette, Mode, Encounter, State }` and lock the `traits` field of `OutputSummary` and `OutputDetailResponse` to that shape. Contract truth: tokens carry **three universal attributes** (`Token Hash`, `Token Number`, `Artist`), and per-Project generative traits are computed off-chain by the indexer. The second Project at launch (after Kiki) will have different trait names and break these types.

**Recommended resolution:** make the `traits` field generic — `Record<string, string>` or `Array<{name: string, value: string}>` — so any Project's trait names fit.

**4.5 — `EVENTS` mock data uses unfamiliar token IDs**

`lib/data/tapeEvents.ts` line 84: `['mint', 0, 'minted', 'kiki', 22, null]` — token ID 22 on `kiki`. Token IDs start at 1 per contract; 22 is valid. No issue, flagged only because the literal "22" coincidentally matches the per-tx cap. No conflict.

**Recommended resolution:** no action.

---

## Triage queue

Listed in fix-order for the next chat. Group P0s; P1s sequenced by independence (1.1 needs CEO call, the rest are mechanical).

| # | Sev | File(s) | One-line fix |
|---|---|---|---|
| 1 | **P0** | `components/CalcSheet.tsx` | Replace 5% platform + 3% royalty with single 5% royalty line; delete `CALC_PLATFORM_FEE_PCT` |
| 2 | **P0** | `app/api/project/[slug]/route.ts`, `app/api/artist/[address]/route.ts` | Replace "mint-end + 60 days" with "project_created_at + 60 days"; source from `cooldownRemaining(artist)` |
| 3 | P1 | `lib/state/CartContext.tsx` | Rewrite fee model: primary = mintPrice + storageFeeWei (no royalty); secondary = 5% royalty paid by seller |
| 4 | P1 | `components/CalcSheet.tsx`, `lib/state/CartContext.tsx` | Centralize percentages into `lib/economics.ts` with comments pointing to contract constants |
| 5 | P1 | `components/profile/ProfilePageBody.tsx`, `components/project/ProjectPageBody.tsx` | `aria-label="Gallery"` → `aria-label="Outputs"` (2 hits) |
| 6 | P1 | `pd-contracts/README.md` line 9 | "between drops" → "between Project deploys" |
| 7 | P1 | `lib/calendar/data.ts` line 12 | "Kiki genesis drop (anniversary)" → "Kiki genesis (anniversary)" |
| 8 | P1 | Schema, routes, UI (multi-file) | CEO call: keep `wishlist` (lift the lock) or rename to non-banned word and sweep |
| 9 | P1 | `lib/data/tapeEvents.ts`, `lib/state/ValuePromptContext.tsx`, etc. | CEO call: keep `listing` (lift the lock) or pick replacement and sweep |
| 10 | P1 | `docs/api-spec.md`, `app/api/user/[address]/route.ts` | CEO call on truth; rewrite the other to match |
| 11 | P1 | (forward) mint UI when it ships | Hard-cap quantity input at 22, source from `MAX_MINT_PER_TX` |
| 12 | P1 | (forward) project-creation UI | Validate maxSupply ≤ 10,000, source from `MAX_SUPPLY_CAP` |
| 13 | P1 | (forward) mint UI quote | Add `currentStorageFeeWei` call to mint-quote calculation |
| 14 | P1 | (forward) preview rendering | Document `ar://<txid>/preview.webp` URL contract + "PRESERVING PREVIEW" placeholder state |
| 15 | P1 | `docs/api-spec.md`, indexer (out of scope, flag) | Document `MintFeeDistributed` cumulative-shares trap for indexer team |
| 16 | P1 | `pd-contracts/README.md` lines 20–28 | Add contract-constant cross-reference |
| 17 | P2 | `app/globals.css` (32 hits), TSX (6 hits), `lib/engines/budgetEngine.ts` | `#gallery` → `#outputs-grid` (or equivalent) global rename |
| 18 | P2 | `lib/data/tapeEvents.ts`, `app/api/search/route.ts` | Rename `coll` → `project`, `colRes` → `projectRes` |
| 19 | P2 | `docs/api-spec.md` | Add "Event taxonomy" section mapping `MINT/LIST/SALE/XFER` to on-chain/marketplace sources |
| 20 | P2 | `lib/supabase.ts` | Document or remove `'OFFER'` NotificationType |
| 21 | P2 | `app/api/gas/route.ts` line 43 | After factory deploy, swap Chainlink address literal for `chainlinkFeed()` read |
| 22 | P2 | `app/api/output/[id]/route.ts`, `app/api/project/[slug]/outputs/route.ts` | Make `traits` shape generic (`Record<string, string>` or `Array<{name, value}>`) |

---

## What this audit did not cover

Pass 2 will pick up:
- URL architecture against `/{globalId}`, `/art/{slug}`, `/{handle}` lock
- Supabase RLS policies vs the 9 public tables
- Storage principles (no IPFS, no clientside-only persistent prefs, Arweave for art, PriceSprites for sprites)
- Canonical-domain sweep (pricediscussion.com everywhere)

Also outside this audit's scope:
- The indexer repo (`PriceOS-indexer`) is referenced from `app/api/follows/route.ts` line 38 but not pulled here. The `MintFeeDistributed` cumulative-shares trap (finding 2.2) is where the indexer will most plausibly mis-translate. An indexer-side audit before mainnet would catch it.
- `PDStickers.sol` is in the repo but deferred post-launch per the platform brief; not audited.
