# NodusLayer contracts

Foundry package. See the [repository README](../README.md) for usage and
[`docs/design.md`](../docs/design.md) for the design.

```
src/            StockRegistry, BasketFactory, BasketToken, BasketZap, BasketMigrator, RouteExecutor,
                BasketLens (+ interfaces/)
test/           unit and fuzz tests; test/invariant/ stateful invariants; test/fork/ runs against
                Robinhood Chain when FORK_TESTS=true
script/         Deploy, TimelockAccept, CreateBasket, Govern (timelock-driven), RehearsalFixture,
                Devnet (tokens, feeds and seeded pools for devnet.sh); devnet.sh, verify-basket.sh,
                coverage-floor.sh
config/         robinhood-mainnet.json (external addresses), baskets/*.json (specs), catalogue.json
abi/            published ABI, selectors and errors — the surface other repositories pin to
governance/     one file per scheduled timelock operation
```

`slither.config.json` is the static-analysis triage CI runs with; `.gas-snapshot` is the deterministic
test suite's gas, checked in CI with a 2% tolerance.
