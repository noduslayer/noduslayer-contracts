# Deployments

Nothing is deployed yet. Fill a row in when it is, and keep it in the same commit as any config change that
depends on it.

## Robinhood Chain mainnet (4663)

| Contract | Address | Deployed | Verified |
|---|---|---|---|
| TimelockController | — | — | — |
| StockRegistry | — | — | — |
| BasketFactory | — | — | — |
| BasketZap | — | — | — |
| BasketMigrator | — | — | — |
| BasketLens | — | — | — |

| Parameter | Value |
|---|---|
| Multisig | — |
| Treasury | — |
| Timelock min delay | — |
| Zap fee | — |

## Robinhood Chain testnet (46630)

| Contract | Address | Deployed | Verified |
|---|---|---|---|
| TimelockController | `0x3dd92740fb719Fe2Ef1a209c54E0DBC9Eb203350` | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x3dd92740fb719Fe2Ef1a209c54E0DBC9Eb203350?tab=contract) |
| StockRegistry | `0xD515398BFAFe01b6c9642053fbF76186A0410f3F` | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xD515398BFAFe01b6c9642053fbF76186A0410f3F?tab=contract) |
| BasketFactory | `0xe85cCCdA8B866d83a94028038B4b20b8a3e1b0BA` | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xe85cCCdA8B866d83a94028038B4b20b8a3e1b0BA?tab=contract) |
| BasketZap | `0x77e8a118A81307194517982250b5e1DE43d388A1` | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x77e8a118A81307194517982250b5e1DE43d388A1?tab=contract) |
| BasketMigrator | `0x2caDE741ECe352B524B0cAea10FD8e4EEFcD73BE` | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x2caDE741ECe352B524B0cAea10FD8e4EEFcD73BE?tab=contract) |
| BasketLens | `0x4fe58c19ca4E752b225Ae90E1158Cf8B6F4B1572` | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x4fe58c19ca4E752b225Ae90E1158Cf8B6F4B1572?tab=contract) |

| Parameter | Value |
|---|---|
| Multisig (proposer, canceller, executor) | the deployer, `0x262E53ec3A8E8Bcb23d44E6352B1b0C43387e8dD` |
| Treasury | the deployer |
| Timelock min delay | 0 (a rehearsal that finishes in one sitting; the mainnet runbook uses 2 days) |
| Zap fee | 20 bps |
| Deployed from block | 114054675 |

Deployed by `script/testnet.sh`. Testnet mirrors nothing of mainnet, so the market this runs on is the
script's own: `config/robinhood-testnet.json` names the stand-in stock tokens (mintable, 18 decimals),
their feeds (fixed at mainnet's prices when deployed), a mintable USDG and WETH, and a Uniswap v3 factory,
SwapRouter02 and QuoterV2 deployed from the published bytecode, with a 0.05% pool of deep liquidity for
every token against both USDG and WETH. The broadcast records are under `broadcast/*/46630/`. The six contracts above, the test USDG and WETH,
and every basket have their sources verified on the testnet Blockscout (2026-09-06).

## Baskets (testnet)

Created by `script/testnet.sh` in five timelock operations of six, in the order of `config/baskets/`.

| Symbol | Address | Recipe | Created | Verified | Retired → successor |
|---|---|---|---|---|---|
| `ADS` | `0xAF63E45Ab36667B83550Bf4067e699bd7531B28c` | GOOGL 50% / META 50% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xAF63E45Ab36667B83550Bf4067e699bd7531B28c?tab=contract) | — |
| `AI` | `0xE9D54E1787157d4ca614CE00ce1926092cFB74f9` | NVDA 30% / AMD 20% / TSM 20% / MU 15% / PLTR 15% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xE9D54E1787157d4ca614CE00ce1926092cFB74f9?tab=contract) | — |
| `AIINF` | `0x872e458E4973614C419E661Fc180FE8cAd4dcE82` | NVDA 30% / MU 25% / DELL 20% / SNDK 15% / CRWV 8% / NBIS 2% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x872e458E4973614C419E661Fc180FE8cAd4dcE82?tab=contract) | — |
| `ALLW` | `0x711C9E2F49a3C529F5E55b19987d0a4D6dD84D8c` | SPY 35% / SGOV 30% / SLV 20% / USO 15% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x711C9E2F49a3C529F5E55b19987d0a4D6dD84D8c?tab=contract) | — |
| `ASIA` | `0xAAf2Ac67924f4c631aaE7D90C9dB900F580C708C` | TSM 50% / BABA 44% / EWY 6% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xAAf2Ac67924f4c631aaE7D90C9dB900F580C708C?tab=contract) | — |
| `BAL` | `0xE077F0dD063105483325e8bDeb0cAc02Acb00775` | SPY 40% / SGOV 30% / NVDA 20% / SLV 10% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xE077F0dD063105483325e8bDeb0cAc02Acb00775?tab=contract) | — |
| `BROAD` | `0x93d8d7f68969012260Ef185d1C9f3A78971e339d` | SPY 60% / QQQ 40% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x93d8d7f68969012260Ef185d1C9f3A78971e339d?tab=contract) | — |
| `CLOUD` | `0x2B7aD59158A09Ef22DE1275f75fd97Cc6a319A73` | MSFT 40% / GOOGL 30% / PLTR 22% / ORCL 8% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x2B7aD59158A09Ef22DE1275f75fd97Cc6a319A73?tab=contract) | — |
| `CMDTY` | `0xa443A9a3Ffee1D6B5BBE3E2B1FE6fd002f1bBd05` | SLV 60% / USO 40% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xa443A9a3Ffee1D6B5BBE3E2B1FE6fd002f1bBd05?tab=contract) | — |
| `CRYPTOEQ` | `0xaFEE07e0f77Dd97d890d3E64111C9d5C3bdd31c7` | MSTR 40% / COIN 35% / CRCL 25% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xaFEE07e0f77Dd97d890d3E64111C9d5C3bdd31c7?tab=contract) | — |
| `DATA` | `0x63547852a37a883C97360E2963A32678F05eDb49` | PLTR 45% / MSFT 30% / NVDA 25% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x63547852a37a883C97360E2963A32678F05eDb49?tab=contract) | — |
| `DIAMOND` | `0x5Ed1E9B82aF52d18bC0cb87Ded8d40eA50f6bA12` | GME 35% / MSTR 30% / TSLA 20% / PLTR 15% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x5Ed1E9B82aF52d18bC0cb87Ded8d40eA50f6bA12?tab=contract) | — |
| `EV` | `0x93Af41351137C041D04D59080841F2669E44934F` | TSLA 60% / NVDA 40% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x93Af41351137C041D04D59080841F2669E44934F?tab=contract) | — |
| `FNDRY` | `0xD3B75Ff617F1D102303ffba9bB49a29e10D7f791` | TSM 50% / ASML 30% / INTC 20% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xD3B75Ff617F1D102303ffba9bB49a29e10D7f791?tab=contract) | — |
| `GPU` | `0x6fE970F82236558b1C5eFA70643A1D3Dc6Ca1CB4` | NVDA 60% / AMD 40% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x6fE970F82236558b1C5eFA70643A1D3Dc6Ca1CB4?tab=contract) | — |
| `GROWTH` | `0x0EFA011AE19C5D7399C82dB9F94B907bf0364877` | NVDA 30% / PLTR 25% / CRCL 25% / MSTR 20% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x0EFA011AE19C5D7399C82dB9F94B907bf0364877?tab=contract) | — |
| `HDWR` | `0x469974039683F4E9d355d58086eB6A3b69DA0A12` | AAPL 40% / DELL 30% / SNDK 30% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x469974039683F4E9d355d58086eB6A3b69DA0A12?tab=contract) | — |
| `INFL` | `0x71370bA9A39bfa94599c18E0f49c537A6c4888bD` | SLV 40% / USO 30% / USAR 30% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x71370bA9A39bfa94599c18E0f49c537A6c4888bD?tab=contract) | — |
| `MAG7` | `0xE792Ec410d987c58eC7C7511c46Cf0DCf8086b00` | NVDA 20% / AAPL 15% / MSFT 15% / GOOGL 15% / AMZN 15% / META 12% / TSLA 8% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xE792Ec410d987c58eC7C7511c46Cf0DCf8086b00?tab=contract) | — |
| `MEM` | `0x98a0E95C11962BD85C2220B9d04D4A53202A3bC6` | MU 50% / SNDK 50% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x98a0E95C11962BD85C2220B9d04D4A53202A3bC6?tab=contract) | — |
| `QNTM` | `0xd74606aA288e885908d55f956b224c786d14Ac83` | NVDA 70% / CRWV 8% / RGTI 5% / RKLB 5% / IONQ 4% / CLSK 4% / NBIS 4% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xd74606aA288e885908d55f956b224c786d14Ac83?tab=contract) | — |
| `RETAIL` | `0xfE10A7EA67318D232E2f5454b891e4Ad729E507D` | GME 40% / AMZN 35% / TSLA 25% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xfE10A7EA67318D232E2f5454b891e4Ad729E507D?tab=contract) | — |
| `SEMI` | `0x4a6f4B852CCCad6D4A748f8BE158577D9A1795EA` | NVDA 30% / TSM 20% / AMD 20% / MU 15% / ASML 10% / INTC 5% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x4a6f4B852CCCad6D4A748f8BE158577D9A1795EA?tab=contract) | — |
| `SIXTY40` | `0x3b256ABb6E0036e712A541fDc0B005819e89deb5` | SPY 60% / SGOV 40% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x3b256ABb6E0036e712A541fDc0B005819e89deb5?tab=contract) | — |
| `SPACE` | `0xbDd35Cf962997088C136C764567A0a66Bedcdb81` | SPCX 85% / RKLB 15% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xbDd35Cf962997088C136C764567A0a66Bedcdb81?tab=contract) | — |
| `STONKS` | `0x3133969A9150524381A1861c8cfcF9a770F55A36` | GME 30% / TSLA 25% / MSTR 25% / COIN 20% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x3133969A9150524381A1861c8cfcF9a770F55A36?tab=contract) | — |
| `TECH` | `0xbA98CEBD6F86dAFF6c1293421988aB01D9CB210D` | NVDA 30% / AAPL 25% / GOOGL 25% / MSFT 20% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xbA98CEBD6F86dAFF6c1293421988aB01D9CB210D?tab=contract) | — |
| `TENDIES` | `0x81CE51b0BEaB98509800d977E945B93a8d88dB06` | GME 30% / AMZN 30% / TSLA 25% / COIN 15% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0x81CE51b0BEaB98509800d977E945B93a8d88dB06?tab=contract) | — |
| `VALUE` | `0xc587B110f3c0FaF38430a326eB850f681571B9A0` | INTC 32% / BABA 32% / DELL 28% / ORCL 8% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xc587B110f3c0FaF38430a326eB850f681571B9A0?tab=contract) | — |
| `YOLO` | `0xD6567E3cB295b23164A7020097F977f889B28D0a` | MSTR 55% / GME 45% | 2026-09-06 | [Blockscout](https://explorer.testnet.chain.robinhood.com/address/0xD6567E3cB295b23164A7020097F977f889B28D0a?tab=contract) | — |

Verify each basket's source with `BASKET=0x... contracts/script/verify-basket.sh` after the creating
operation executes; the factory deploys them, so the deploy's `--verify` does not cover them.

## Verifying a deployment

```sh
export REGISTRY=0x... FACTORY=0x... ZAP=0x... MIGRATOR=0x... TIMELOCK=0x...

# ownership sits with the timelock, not the deployer
for c in $REGISTRY $FACTORY $ZAP $MIGRATOR; do cast call $c "owner()(address)" --rpc-url robinhood; done

# the zap and the migrator point at the factory they were deployed against, and neither is paused
for c in $ZAP $MIGRATOR; do cast call $c "factory()(address)" --rpc-url robinhood; cast call $c "paused()(bool)" --rpc-url robinhood; done

# the zap wraps into the WETH the config names
cast call $ZAP "weth()(address)" --rpc-url robinhood

# the registry lists what the config says it should
cast call $REGISTRY "tokens()(address[])" --rpc-url robinhood | tr ',' '\n' | wc -l
```
