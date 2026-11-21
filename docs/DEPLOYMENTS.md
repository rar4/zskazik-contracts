# Deployments

## Base Sepolia (84532) — current

Deployed 2026-11-21 from the burner wallet (master/owner):

    0x20a0513538df6290f22efdb5Fd1deb044313d579

| Contract   | Address                                    |
|------------|--------------------------------------------|
| CasinoToken| 0x79d782fFb87a643b9C5369F54f0c1fCa02f40A89 |
| Treasury   | 0xa84A9505753e0bE52486E181bD9dde77D261ad56 |
| CoinFlip   | 0x22157527B27C4E3174215126c100f66B041cF082 |
| Dice       | 0xe3192207Fa9Da7BdBFfd09E0F01FB49C14E59b04 |
| Plinko     | 0x1a2a89BFDD940B34f62237b6cCb4b8D2644a37cD |

RPC: https://sepolia.base.org · Explorer: https://sepolia.basescan.org

Bankroll: 20,000,000 ZSK transferred to Treasury at deploy time.
Token, Treasury and Plinko land on the same addresses as the old Sepolia
deployment (same deployer nonce + bytecode); CoinFlip/Dice are the
single-generation Base deployments (the Sepolia V2 addresses do not
exist on Base).

Deploy commands (same as Sepolia, just the RPC URL changes):

    INITIAL_OWNER=0x20a0...d579 forge script script/DeployCasinoToken.s.sol \
      --rpc-url https://sepolia.base.org --broadcast
    CASINO_TOKEN=0x79d7...0A89 INITIAL_OWNER=0x20a0...d579 \
      forge script script/DeployTreasury.s.sol \
      --rpc-url https://sepolia.base.org --broadcast
    TREASURY=0xa84A...ad56 INITIAL_OWNER=0x20a0...d579 \
      forge script script/DeployGames.s.sol \
      --rpc-url https://sepolia.base.org --broadcast
    # then: token.setTreasury(treasury) + transfer bankroll to treasury

## Ethereum Sepolia (11155111) — deprecated 2026-11-21

Superseded by the Base Sepolia deployment above. Token/Treasury/Plinko
share addresses with Base Sepolia; CoinFlip/Dice were the V2 pair
(0x3ca2... / 0xF4Bf...). Old token cleanup: burner balance burned,
Treasury withdrawn + burned, token paused by owner. Tokens in other
wallets cannot be burned without their keys and remain frozen by the pause.
