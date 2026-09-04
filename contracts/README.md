# NodusLayer contracts

Foundry package. See the [repository README](../README.md) for usage and
[`docs/design.md`](../docs/design.md) for the design.

```
src/            StockRegistry, BasketFactory, BasketToken, BasketZap, BasketLens (+ interfaces/)
test/           unit and fuzz tests; test/fork/ runs against Robinhood Chain when FORK_TESTS=true
script/         Deploy.s.sol, CreateBasket.s.sol (config-driven)
config/         robinhood-mainnet.json (external addresses), baskets/*.json (recipes)
```
