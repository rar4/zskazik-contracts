# ZSKazik Games

`contracts/games/`: `GameBase` + `CoinFlip` (1.96x, 2% edge), `Dice`
(roll-over 1..99, `wager*98/(100-target)`, up to 98x at target 99), `Plinko` (8/12/16 rows, table mults,
max 16x). All: `place -> resolve` in a later block, escrow via
`Treasury.escrowBet`, settle via `Treasury.settleBet` (win pays, loss burns half).

- Randomness is TESTNET-grade (`keccak(betId, prevrandao, placeBlock)`).
  Mainnet must swap `GameBase._random` for Chainlink VRF + fulfill callback.
- Treasury caps must fit games: multiplier >= 100 (Dice 98x at target 99), maxPayout >= wager*98 for max target.
- Refunds: player after 7200 blocks, game/treasury owner anytime (stake back, no burn).
- Deploy: `TREASURY=0x… INITIAL_OWNER=0xMultisig forge script script/DeployGames.s.sol --broadcast`.
- 17 tests in `test/Games.t.sol` (forced win/loss via `vm.prevrandao`, caps, pause, revoke).
