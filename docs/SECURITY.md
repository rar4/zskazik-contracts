# ZSKazik Security Notes (v2.0.0)

Audited-style review of `contracts/CasinoToken.sol`
(OpenZeppelin Contracts v5.7.0, solc 0.8.30, optimizer 1000 runs).

## Trust model

- **Owner (multisig REQUIRED)** can pause/unpause transfers and set treasury,
  plus 2-step transfer/renounce ownership. Deploy `initialOwner` directly to a
  multisig. `transferOwnership` no longer moves authority alone — the new owner
  must call `acceptOwnership()` (typo-safety). Renouncing permanently disables
  pause AND treasury wiring.
- **No privileged mint, burn, freeze, or fee.** Owner cannot touch user funds.
- **No per-address freeze.** To contain one exploiter without halting the whole
  casino, suspend at Treasury/game level, not via global `pause()`.

## Findings & design rationale (v2 — all fixed)

1. **Pause blocks burns too (standard).** `ERC20Pausable._update` gates
   `burn`/`burnFrom` through `whenNotPaused`. During an incident nothing moves,
   including burns. Approvals/`permit` keep working (standard revocation path).
   Tested (`test_Pause_BurnRevertsWhilePaused`,
   `test_Pause_ApproveStillWorksWhilePaused`,
   `test_Pause_PermitStillWorksWhilePaused`). Operational rule: announce unpause
   with a delay; permits granted mid-pause become usable at unpause.
2. **Percentages fixed with bps.** `burnedBasisPoints()` / `remainingBasisPoints()`
   (0–10000) are primary; legacy 0–100 wrappers divide by 100. Dust sums can read
   9999 — dashboards must use bps (`assertApproxEqAbs(...,1)` in fuzz).
3. **`totalBurned` counts only true burns.** Detection is
   `to == address(0) && from != address(0)` inside `_update`, so the
   constructor mint (`from == address(0)`) never inflates the counter.
4. **Standard pause events.** v1 custom `ContractPaused/Unpaused` removed; the
   contract emits OZ `Paused`/`Unpaused`. Indexers/multisig tooling compatible.
5. **EIP-2612 domain** uses token name `"ZSKazik"` at deployment; no
   upgradeability means no domain-change concerns.
6. **Approval race.** OZ v5 has no `increaseAllowance`; recommend `approve(0)`-then-
   `approve(n)` or `permit()` for allowance changes. Treasury integrations should
   pull exact stakes via `transferFrom` with expiring permits.

## Standard protections inherited from OZ v5.7.0

- Overflow-safe arithmetic (Solidity 0.8 checked math).
- `ERC20InvalidReceiver` blocks transfers to `address(0)` (use `burn`).
- `ERC20InsufficientBalance` / `ERC20InsufficientAllowance` on overdrafts.
- Permit: deadline enforcement (`ERC2612ExpiredSignature`), signer binding
  (`ERC2612InvalidSigner`), single-use nonces (replay reverts) — all covered
  in `test_Permit_*`, including fuzz-adjacent replay checks.
- `Ownable2Step`: zero-address owner rejected at construction
  (`OwnableInvalidOwner`); pause/unpause/treasury restricted
  (`OwnableUnauthorizedAccount`); wrong-acceptor reverts.
- No `delegatecall`, no inline assembly, no external calls, no ether handling
  (no `receive`/`fallback` — plain ETH sent to the token reverts).

## Test coverage

48 Foundry tests, all passing (`forge test`): deployment, fixed-supply
invariants, burn mechanics + events, bps granularity, treasury exclusion matrix,
pause/unpause matrix with standard events (incl. owner-is-blocked
and permit-while-paused), full EIP-2612 vectors (valid / expired / wrong-signer /
replay), transfers, approvals, 2-step ownership lifecycle, plus fuzz tests proving
`totalSupply + totalBurned == initialSupply` and bps sums == 10000 ±1.

## Pre-launch checklist for the deployer

- [ ] Deploy with `INITIAL_OWNER=<multisig>` in one tx (never EOA-then-transfer).
- [ ] Distribute before LP: Treasury fund + `setTreasury()`, LP seed + lock, team vesting via VestingWallet.
- [ ] Verify source on the block explorer (flattened or standard-json).
- [ ] Decide pause policy: keep owner-managed multisig with public unpause delay, or `renounceOwnership`
      (note: renouncing permanently disables pause AND treasury wiring).
- [ ] Treasury/games: atomic `lossSplit`, bankroll solvency proof, VRF, RTP caps — separate review, out of scope here.
