# ZSKazik Tokenomics (v2.0.0)

## Supply schedule

| Parameter | Value |
|---|---|
| Name / Symbol | ZSKazik / ZSKAZIK |
| Decimals | 18 |
| Initial & max supply | 1,000,000,000 ZSKAZIK (minted once in constructor) |
| Inflation | None — no mint function exists |
| Emission schedule | None — distribution is post-deploy transfers (see below), not emissions |
| Deflation | Burns only (`burn` / `burnFrom`), tracked in `totalBurned` |

Supply over time: `totalSupply(t) = 1,000,000,000 − totalBurned(t)`.
`totalBurned` is monotonically increasing; supply is monotonically
non-increasing. `initialSupply` is immutable and permanently records the
ceiling, so bps/percent views are always denominated against the original 1B.

## Distribution (operational — not in token code)

Token mints 100% to `initialOwner` in one tx. Deploy `initialOwner` DIRECTLY to
a multisig (`INITIAL_OWNER=0xMultisig`), then split via plain transfers, e.g:

- Bankroll/Treasury: fund with explicit amounts, then `setTreasury(treasury)`
  so `circulatingSupply()` excludes it.
- LP: seed with a small % + lock LP tokens (never LP 100% from one wallet).
- Team/vesting: use a VestingWallet, never a bare EOA.

No vesting lives in the token by design — use OZ `VestingWallet` externally.
Full-supply-to-one-EOA + immediate LP = bot/CEX red flag; distribute first.

## The future loss flow (policy for Treasury.sol, NOT implemented here)

```text
Player loses 100 ZSKAZIK
  → 50 ZSKAZIK burned   (supply ↓, totalBurned ↑, TokensBurned emitted)
  → 50 ZSKAZIK to Treasury (plain ERC20 transfer, supply unchanged)
```

Must be ATOMIC in Treasury (`lossSplit(player, amount)` → `transferFrom` +
`burn` in one call). Two separate user txs = fail-halfway / frontrun / grief.

Net effect per 100 ZSKAZIK lost: **−50 supply, +50 Treasury bankroll.**
Wins are paid from Treasury holdings — never minted. RTP is therefore bounded
by Treasury balance plus recycled stakes, and the token can only deflate.

Why this split:

- **Burn half** — permanent deflation rewards long-term holders and offsets
  payout emissions from the bankroll.
- **Treasury half** — capitalizes the bankroll so wins are always fully
  collateralized; no fractional-reserve payouts.

## On-chain analytics (this contract)

| Function | Returns | Use |
|---|---|---|
| `totalBurned` | wei burned to date | Deflation dashboards |
| `currentSupply()` | live `totalSupply()` | Supply widgets |
| `circulatingSupply()` | `totalSupply() - treasury` | Aggregators (honest circulation) |
| `burnedBasisPoints()` | uint 0–10000 | Precise "X% burned" displays (preferred) |
| `remainingBasisPoints()` | uint 0–10000 | Complement (sums to 10000 ±1 on dust) |
| `burnedPercentage()` | uint 0–100 legacy | Whole-percent displays only |
| `remainingSupplyPercentage()` | uint 0–100 legacy | Whole-percent displays only |
| `TokensBurned(account, amount)` | event per burn | Indexers, burn leaderboards |

Bps use integer division floor. Frontends needing decimals compute from
`totalBurned`/`initialSupply` or use bps (1% = 100 bps, 0.01% = 1 bps).

## What the token deliberately does NOT do

- No staking rewards, no rebases, no reflections.
- No fees-on-transfer (transfers are 1:1 — safe for vault/Treasury math).
- No allowlists/blocklists, no freezing of individual accounts (pause is global).
- No treasury split, no RTP, no randomness — those belong to Treasury/games.

Any future tokenomics change (e.g. buyback-and-burn in Treasury) composes with
this token through the standard ERC20 + burn interface without modification.
