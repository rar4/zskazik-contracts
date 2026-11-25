# ZSKazik Treasury

Bankroll + accounting layer. Holds ZSKAZIK, escrows bets from authorized games,
pays wins, keeps the full lost wager, and burns only the bankroll above
`burnThreshold` (20M ZSK). `contracts/Treasury.sol`
(OZ `Ownable2Step`, `Pausable`, `ReentrancyGuard`, `SafeERC20`).

## Lifecycle

```text
Player approves Treasury
  -> game.escrowBet(player, wager, betId)   // transferFrom player -> treasury
  -> game.settleBet(betId, payout)          // payout>0 win / payout==0 loss
       win:  transfer(player, payout)        // payout INCLUDES stake (100 at 2x = 200)
       loss: keep full wager; burn only bankroll above burnThreshold (20M)
```

No-escrow shortcut: `splitLossDirect(player, amount, betId)` pulls + keeps
in one tx, burning only the amount above the threshold. One-tx UX:
`depositWithPermit` / `escrowBetWithPermit` (EIP-2612).

## Threshold burn

- `burnThreshold` defaults to 20M ZSK, owner-set via `setBurnThreshold`
  (`0` disables). Below the threshold nothing is burned, so the bankroll
  keeps the full loss and grows steadily toward 20M.
- On settle (win or loss) and `splitLossDirect`, any bankroll above the
  threshold is burned, never below `activeWager`. `excessOverThreshold()`
  shows the burnable amount; `burnExcessOverThreshold()` (owner) trims a
  bankroll funded above the threshold via `deposit` (deposits do not
  auto-burn — raise the threshold first if funding above it).

## Caps (all owner-set, `setLimits`)

| Cap | Meaning |
|---|---|
| `minBet` | Dust guard (reverts below) |
| `maxBet` | Max wager per bet |
| `maxPayout` | Absolute max payout |
| `maxWinMultiplier` | Relative max: `payout <= wager * multiplier` (blocks 1-wei -> maxPayout drain) |
| `maxTotalExposure` | Max sum of unsettled wagers (`0` = uncapped, not recommended) |

Solvency enforced on-chain: win reverts `InsolventBankroll` if `payout > bankroll`.
Withdraw reverts `WouldLeaveInsolvent` if it would eat escrowed stakes.

## Stuck funds (fixed)

- `cancelBet(betId)` — game voids a round, full stake back to player.
- `emergencyRefundBet(betId)` — owner refunds player after revoke/abandon.
  Works while Treasury paused. Still reverts if the TOKEN is paused
  (transfers frozen at token layer — same emergency).
- `revokeGame` never strands: existing escrows stay settleable/cancellable.

## Game integration

```solidity
bytes32 betId = keccak256(abi.encode(address(this), player, nonce++));
treasury.escrowBet(player, wager, betId);
// ... resolve randomness (Chainlink VRF, never block.timestamp alone) ...
treasury.settleBet(betId, payout); // 0 = loss
```

Rules: unique `betId` per bet, settle exactly once, `payout` includes stake,
only whitelisted `isGame` may call. Randomness/RTP live in games, not here.

## Deploy / wire

```bash
CASINO_TOKEN=0xToken INITIAL_OWNER=0xMultisig \
forge script script/DeployTreasury.s.sol --rpc-url <RPC> --broadcast
# then, as TOKEN owner:
token.setTreasury(address(treasury))
# then, as TREASURY owner:
treasury.authorizeGame(dice); treasury.authorizeGame(plinko);
token.transfer(treasury, bankroll); # or approve + treasury.deposit()
```

## What was fixed vs the first draft

- Added `minBet`, `maxWinMultiplier`, `maxTotalExposure` + `activeWager`/`activeBetCount`.
- Withdraw can no longer steal escrowed stakes.
- `deposit` works while paused (recapitalize in incidents).
- `cancelBet` + `emergencyRefundBet` close the stuck-escrow hole.
- Permit variants for one-tx bet/deposit.
- `nonReentrant` first, state before external calls, custom errors, full events.
- 41 Treasury tests: auth, escrow/settle win/loss, threshold burn (below keeps
  full, at cap burns excess, crossing burns only the excess, manual burn,
  activeWager floor, disabled at 0),
  double-settle/duplicate/revoke guards, cap/exposure/insolvency reverts, pause matrix,
  permit flows, fuzz win/loss accounting.
