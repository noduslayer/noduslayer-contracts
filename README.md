# NodusLayer

Index baskets of Robinhood Chain stock tokens, redeemable in kind, bought and sold in one
transaction through a routing layer. Robinhood Chain mainnet (chain id 4663).

```
contracts/   Solidity (Foundry) — vault, factory, registry, zap, lens, deploy scripts
docs/        design.md, audit/ (static-analysis output and the internal review)
services/    (phase 2) quote service: pool graph, route search, calldata encoding
apps/        (phase 2) web app
```

## Contracts

| Contract | Role |
|---|---|
| `StockRegistry` | Canonical stock-token addresses and their Chainlink feeds. Gates basket creation. |
| `BasketFactory` | Deploys baskets, validates constituents against the registry, records official baskets. |
| `BasketToken` | The basket: ERC-20 (+permit) backed 1:1 by a fixed recipe; mint/redeem in kind; never pausable. |
| `BasketZap` | Buy or sell a basket in one transaction via allow-listed routers; refunds every leftover. |
| `BasketLens` | Read-only NAV and per-constituent quotes from Chainlink. |

Design notes, invariants and the fee model: [`docs/design.md`](docs/design.md).
Curated basket catalogue: [`docs/baskets.md`](docs/baskets.md).
Constituent universe and liquidity: [`docs/stock-universe.md`](docs/stock-universe.md).
Review findings and threat model: [`docs/audit/2026-09-04-internal-review.md`](docs/audit/2026-09-04-internal-review.md).

## Develop

Requires [Foundry](https://getfoundry.sh) ≥ 1.5.

```sh
cd contracts
forge build
forge test                                   # unit + fuzz
FORK_TESTS=true forge test --match-contract RobinhoodMainnetForkTest -vv   # against mainnet 4663
forge lint && forge fmt --check
```

Static analysis (both write into `out/`; run `forge clean` afterwards before testing again):

```sh
slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
aderyn . -o ../docs/audit/aderyn.md
```

## Deploy

`contracts/config/robinhood-mainnet.json` pins every external address the deployment relies on
(stock tokens, Chainlink feeds, Uniswap routers). Verify it against the sources it cites before
broadcasting — Robinhood publishes canonical token addresses at `docs.robinhood.com/chain/contracts`,
Chainlink at `docs.chain.link`, Uniswap in `Uniswap/contracts/deployments/4663.md`.

```sh
cd contracts
export OWNER=0x...       # multisig or timelock that will accept ownership
export TREASURY=0x...    # fee recipient
forge script script/Deploy.s.sol --rpc-url robinhood --account deployer --broadcast --verify \
  --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api

# OWNER then calls acceptOwnership() on StockRegistry, BasketFactory and BasketZap.

export FACTORY=0x...
BASKET=tech forge script script/CreateBasket.s.sol --rpc-url robinhood --account owner --broadcast
```

Basket recipes live in `contracts/config/baskets/*.json` and declare **target weights**; `units` are derived
from live Chainlink prices at creation. The 60 curated baskets are catalogued in
[`docs/baskets.md`](docs/baskets.md).

## Status

v1 contracts complete with unit, fuzz and mainnet-fork coverage and an internal review. All 194 published
Robinhood stock tokens are listable; 35 have Chainlink feeds and can be priced on-chain. Curated baskets
(`config/baskets/`) ship with the protocol; user-created baskets are not enabled (`createBasket` is
`onlyOwner`). Not yet: independent audit, timelock deployment, quote service, web app. Tokenized stocks are not available
to US persons; the front end must geo-block accordingly, and the product needs legal review in each
jurisdiction it serves.
