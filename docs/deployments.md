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
| TimelockController | — | — | — |
| StockRegistry | — | — | — |
| BasketFactory | — | — | — |
| BasketZap | — | — | — |
| BasketMigrator | — | — | — |
| BasketLens | — | — | — |

The testnet config is not written yet: `contracts/config/` holds only `robinhood-mainnet.json`. Testnet
stock tokens and Chainlink feeds have different addresses, so a `robinhood-testnet.json` has to be built
from testnet state before `CONFIG=robinhood-testnet` will work.

## Baskets

| Symbol | Address | Recipe | Created | Verified | Retired → successor |
|---|---|---|---|---|---|
| — | — | — | — | — | — |

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
