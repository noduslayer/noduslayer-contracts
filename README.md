# noduslayer-contracts

Index baskets of tokenized equities on Robinhood Chain (chain id 4663). A basket is an ERC-20 backed
one-for-one by a fixed recipe of stock tokens. Anyone can mint it by depositing the exact constituents and
redeem it back for them; a zap contract does the same in a single transaction by routing an input token
through allow-listed DEX routers.

## How it works

A recipe pins the constituent amounts backing `1e18` shares, so the vault never prices anything and never
trades. Mint rounds constituent amounts up, redeem rounds them down, and fees settle in shares, which keeps
the backing invariant true for every constituent at all times:

```
balance_i * 1e18  >=  totalSupply * units_i  +  totalClaimable_i * 1e18
```

Redeem has no pause switch and reads no oracle, so holders can always exit to the underlying tokens.
Robinhood stock tokens implement ERC-8056, which applies dividends and splits through a `uiMultiplier()`
rather than rebasing balances, so a recipe expressed in raw units stays correct across corporate actions.

Routing is decided off-chain. The zap only enforces the router allow-list, exact-output backing, the
caller's minimum output, and a deadline. It holds no balance between transactions and refunds every
leftover, so a malformed route can only cost its own sender.

## Contracts

| Contract | Role |
|---|---|
| `StockRegistry` | Canonical stock-token addresses and their optional Chainlink feeds. Gates basket creation. |
| `BasketFactory` | Deploys baskets, validates constituents against the registry, records official baskets. |
| `BasketToken` | The basket: ERC-20 with permit, backed by a fixed recipe. Mint and redeem in kind; never pausable. |
| `BasketZap` | Buy or sell a basket in one transaction through allow-listed routers. |
| `BasketLens` | Read-only NAV and per-constituent quotes from Chainlink. |

- [`docs/design.md`](docs/design.md) — architecture, invariants, fee model, threat model
- [`docs/baskets.md`](docs/baskets.md) — the 60 curated baskets and the depth caps that shaped them
- [`docs/stock-universe.md`](docs/stock-universe.md) — all 194 constituents with measured liquidity
- [`docs/audit/`](docs/audit) — internal review, Slither and Aderyn output

## Development

Requires [Foundry](https://getfoundry.sh) 1.5 or later.

```sh
git clone --recurse-submodules https://github.com/noduslayer/noduslayer-contracts.git
cd noduslayer-contracts/contracts

forge build
forge test                          # unit and fuzz
forge lint && forge fmt --check

FORK_TESTS=true forge test --match-path 'test/fork/*' -vv
```

Fork tests run against Robinhood Chain mainnet. They cover in-kind mint and redeem with real tokens, zap
routing through Uniswap v3, retail gas cost, listing the full universe, and deploying every basket in the
catalogue with live Chainlink prices.

Slither and Aderyn both write into `out/`, so run `forge clean` before testing again:

```sh
slither . --filter-paths "lib/|test/|script/" --exclude-dependencies
aderyn . -o ../docs/audit/aderyn.md
```

## Deployment

`contracts/config/robinhood-mainnet.json` pins every external address the deployment depends on. Verify it
against the sources it cites before broadcasting: Robinhood publishes canonical token addresses at
`docs.robinhood.com/chain/contracts`, Chainlink feeds are listed at `docs.chain.link`, and Uniswap
deployments live in `Uniswap/contracts/deployments/4663.md`.

```sh
cd contracts
export OWNER=0x...       # multisig or timelock that will accept ownership
export TREASURY=0x...    # fee recipient

forge script script/Deploy.s.sol --rpc-url robinhood --account deployer --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
```

Ownership transfer is two-step: `OWNER` must call `acceptOwnership()` on the registry, factory and zap.
Then create baskets:

```sh
export FACTORY=0x...
BASKET=tech forge script script/CreateBasket.s.sol --rpc-url robinhood --account owner --broadcast
```

Basket specs under `contracts/config/baskets/` declare target weights rather than raw units. The script
reads live Chainlink prices at creation to derive units, and rejects a recipe whose weights breach a
constituent's depth cap, fall below the 1% floor, fail to sum to 100%, or name a constituent with no feed.

## Status

The v1 contracts are complete, with unit, fuzz and mainnet-fork coverage and an internal review. All 194
published Robinhood stock tokens can be listed; 35 carry a Chainlink feed and can be priced on-chain.
Baskets are curated by the protocol — `createBasket` is `onlyOwner`.

Still outstanding: an independent audit, deployment behind a timelock, the off-chain quote service, and a
front end.

Tokenized equities on Robinhood Chain are not available to US persons. Any front end must geo-block
accordingly, and the product needs legal review in every jurisdiction it serves.

## License

MIT
