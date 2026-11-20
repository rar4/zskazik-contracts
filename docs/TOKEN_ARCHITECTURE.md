# ZSKazik Token Architecture (v2.0.0)

## Position in the ecosystem

```text
CasinoToken (this contract — asset layer)
    ↓ ERC20 interface only (transferFrom / burn / burnFrom / permit)
Treasury (future — accounting layer, holds ZSKAZIK, splits losses)
    ↓ payouts / bankroll funding
Dice / Plinko / CoinFlip (future — game logic, randomness, RTP)
```

Dependency rule: **game contracts and Treasury depend on the token; the token
depends on nothing in the ecosystem.** `CasinoToken.sol` imports only
OpenZeppelin and forge-std (tests/scripts). It has no address of, and no call
into, any future contract — except a view-only `treasury` address used solely
for honest `circulatingSupply()` math (no control, no custody).

## Contract map

| File | Role |
|---|---|
| `contracts/CasinoToken.sol` | ERC20 + Burnable + Permit + Ownable2Step + ERC20Pausable. Mint-once supply, burn tracking, treasury-aware circulation, emergency pause. |
| `script/DeployCasinoToken.s.sol` | Deployment script. Deploys with `INITIAL_OWNER` (multisig) — never forced to deployer EOA. |
| `test/CasinoToken.t.sol` | 48 Foundry tests (unit + fuzz) covering every behavior below. |

## Inheritance (OpenZeppelin Contracts v5.7.0)

- `ERC20` — transfers, approvals, allowances.
- `ERC20Burnable` — `burn()` / `burnFrom()`.
- `ERC20Permit` — gasless EIP-2612 approvals (`permit()`).
- `Ownable2Step` — single owner = pause/unpause + setTreasury authority. 2-step transfer, renounceable.
- `ERC20Pausable` — audited emergency stop (standard `Paused`/`Unpaused` events).

## Key design decisions (v2 fixes)

1. **Mint-once, immutable ceiling.** The constructor mints `FIXED_SUPPLY`
   (1B × 10¹⁸) to `initialOwner`. No other mint path exists — verified by
   `test_FixedSupply_NoMintSelector` and by inspection (only `_mint` call site
   is the constructor).
2. **Audited pause path.** Burn/transfer gating comes from `ERC20Pausable._update`
   (`whenNotPaused`), not a custom modifier. Our `_update` override only adds
   `totalBurned` accounting + `TokensBurned` after `super._update`. Custom
   `ContractPaused/Unpaused` events removed — indexers listen for standard
   `Paused`/`Unpaused`.
3. **Approvals bypass the pause (standard).** `approve`/`allowance`/`permit` never touch
   `_update`, so revocation works while paused. Operational rule: multisig owner +
   public unpause timelock, so a permit granted mid-pause cannot be frontrun at unpause.
4. **Burn accounting lives in the token; burn POLICY lives in Treasury.**
   The token counts every burned wei (`totalBurned`) but never decides when a
   burn happens. The future 50/50 loss split (burn half / send half to
   Treasury) must be an ATOMIC Treasury function (`lossSplit()` calling
   `transfer` + `burn` in one tx), not two user txs.
5. **`circulatingSupply() = totalSupply() - treasury balance`.**
   `treasury == address(0)` → equals total. After `setTreasury()` the bankroll
   is excluded for honest CMC/CG reporting. No vesting/lock logic in token.
6. **Basis-points analytics.** `burnedBasisPoints()` / `remainingBasisPoints()`
   (0–10000) are primary; `burnedPercentage()` / `remainingSupplyPercentage()`
   are legacy wrappers (`bps / 100`). Dust sums can read 9999 — use bps for exact math.
7. **No per-address freeze in token.** Global pause only. Cheater containment
   belongs in Treasury/games (suspend player), not in halting the whole economy.

## State

| Variable | Mutability | Meaning |
|---|---|---|
| `FIXED_SUPPLY` | `constant` | 1B ZSKAZIK, the eternal ceiling |
| `BPS_DENOMINATOR` | `constant` | 10000 |
| `VERSION` / `CONTRACT_TYPE` | `constant` | `"2.0.0"` / `"ZSKAZIK_TOKEN"` (gas-cheap) |
| `initialSupply` | `immutable` | Set once to `FIXED_SUPPLY` (compat) |
| `totalBurned` | storage | Cumulative burns, monotonically increasing |
| `treasury` | storage | Circulation-excluded bankroll (owner-set) |
| `_balances` / `_allowances` (OZ) | storage | Standard ERC20 ledger |

## Views for integrators

`currentSupply()`, `circulatingSupply()` (treasury-excluded), `burnedBasisPoints()` /
`remainingBasisPoints()` (0–10000, preferred), `burnedPercentage()` /
`remainingSupplyPercentage()` (0–100 legacy), `VERSION` + `version()` →
`"2.0.0"`, `CONTRACT_TYPE` + `contractType()` → `"ZSKAZIK_TOKEN"`.

## Future integration points (NOT in this contract)

- Treasury pulls player stakes: `transferFrom(player, treasury, x)`.
- Treasury executes the burn half atomically: `burn()` / `burnFrom()`.
- Games request payouts through Treasury, never by minting.
- Treasury MUST be reviewed separately: atomic split, bankroll solvency proof, VRF, RTP caps.
