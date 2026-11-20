# CasinoToken (ZSKAZIK) — v2.0.0

Fixed-supply, deflationary ERC20 — the asset layer of the future casino
ecosystem. Token layer only: no betting, treasury, RTP, payouts, randomness,
or game mechanics.

## Stack

Solidity ^0.8.30 · OpenZeppelin Contracts v5.7.0 · Foundry · viem/wagmi frontend

## Layout

```text
contracts/CasinoToken.sol      token (mint-once 1B ZSKAZIK, burnable, Ownable2Step, ERC20Pausable, permit)
script/DeployCasinoToken.s.sol deployment script (INITIAL_OWNER multisig-first)
test/CasinoToken.t.sol         48 Foundry tests (unit + fuzz, all passing)
docs/TOKEN_ARCHITECTURE.md     ecosystem position, inheritance, design decisions
docs/TOKENOMICS.md             supply schedule, distribution, future 50/50 loss flow, analytics
docs/SECURITY.md               trust model, checklist, coverage
```

## Commands

```bash
forge build                    # compile (solc 0.8.30, optimizer 1000 runs)
forge test                     # 48 tests, incl. fuzz (runs 1000 / invariant 512x25)
forge test -vvv                # verbose
INITIAL_OWNER=0xMultisig forge script script/DeployCasinoToken.s.sol \
  --rpc-url <RPC> --broadcast   # deploy straight to multisig
```

## Key facts

- Entire 1,000,000,000 ZSKAZIK minted once to `initialOwner` (deploy to multisig); no mint function.
- Supply only decreases via `burn`/`burnFrom`; every burn bumps `totalBurned`
  and emits `TokensBurned` (+ standard `Transfer`).
- `pause()`/`unpause()` (owner only, 2-step-owned) halt transfers AND burns;
  approvals and EIP-2612 `permit()` keep working while paused. Standard
  `Paused`/`Unpaused` events.
- `circulatingSupply() = totalSupply() - treasury` (honest aggregator math);
  `burnedBasisPoints()`/`remainingBasisPoints()` (0–10000) are primary analytics.
- Future Treasury/games integrate purely through the ERC20 interface + atomic
  `lossSplit` in Treasury (not two user txs).
