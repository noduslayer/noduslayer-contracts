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
leftover, so a malformed route can only cost its own sender. Its fee is charged on what the route spent,
not on what was sent; the input can be a token, a token with an EIP-2612 permit, or ether.

A recipe never changes. A rebalance is a new basket plus a migrator that trades only the difference, and
the old basket is retired: closed to new shares, open for every exit, pointing at its successor on-chain.

## Contracts

| Contract | Role |
|---|---|
| `StockRegistry` | Canonical stock-token addresses and their optional Chainlink feeds. Gates basket creation. |
| `BasketFactory` | Deploys baskets, validates constituents against the registry, records official baskets. |
| `BasketToken` | The basket: ERC-20 with permit, backed by a fixed recipe. Mint and redeem in kind; never pausable. |
| `BasketZap` | Buy or sell a basket in one transaction through allow-listed routers, from a token, a permit or ether. |
| `BasketMigrator` | Move a holder from one basket version to the next, trading only the legs that changed. |
| `BasketLens` | Read-only NAV and per-constituent quotes from Chainlink. |

- [`docs/design.md`](docs/design.md) — architecture, invariants, fee model, threat model
- [`docs/runbook.md`](docs/runbook.md) — deployment, governance and incident response
- [`docs/baskets.md`](docs/baskets.md) — the 30 curated baskets and the depth caps that shaped them
- [`docs/stock-universe.md`](docs/stock-universe.md) — all 194 constituents with measured liquidity
- [`docs/deployments.md`](docs/deployments.md) — deployed addresses
- [`docs/audit/`](docs/audit) — internal review, Slither and Aderyn output

## Related repositories

[`noduslayer-quoter`](https://github.com/noduslayer/noduslayer-quoter) is the read-only route quoting
service. It encodes calls to these contracts by hand, so it pins itself to [`contracts/abi`](contracts/abi)
— `selectors.json` is published from this repository and asserted there, which turns a signature change into
a failing test rather than a reverted transaction.

[`noduslayer-app`](https://github.com/noduslayer/noduslayer-app) is the web app: the landing page and the
trading interface, which reads and quotes through the quoter and sends the calldata it returns.

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

`script/devnet.sh` stands up the whole protocol on a local anvil with Robinhood Chain's id: the mainnet
Uniswap v3 bytecode, seeded pools priced from the live Chainlink feeds, the deployment, the timelock
hand-over and every basket in `config/baskets/`. It writes `.devnet.env` for the quoter and the app, which
run their end-to-end suites against it. The public RPC keeps only a few thousand blocks of state, so this
replaces forking mainnet.

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
export MULTISIG=0x...            # proposer and executor on the timelock
export TREASURY=0x...            # fee recipient
export TIMELOCK_MIN_DELAY=172800 # 2 days

forge script script/Deploy.s.sol --rpc-url robinhood --account deployer --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
```

This also deploys a `TimelockController` and stages ownership of the registry, factory and zap to it.
Ownership is two-step and the incoming owner is the timelock, so acceptance is itself a scheduled action —
`script/TimelockAccept.s.sol` drives it. [`docs/runbook.md`](docs/runbook.md) has the full sequence and the
checks to run afterwards. Creating baskets is a scheduled action too, since the factory belongs to the
timelock:

```sh
export FACTORY=0x... TIMELOCK=0x... MULTISIG=0x...
BASKETS=tech,ai MODE=schedule forge script script/CreateBasket.s.sol --rpc-url robinhood --sender $MULTISIG
# submit the printed transaction from the multisig; after the delay, MODE=execute OP=<id>
```

Basket specs under `contracts/config/baskets/` declare target weights rather than raw units. The script
reads live Chainlink prices when it schedules to derive units, rejects a recipe whose weights breach a
constituent's depth cap, fall below the 1% floor, fail to sum to 100%, or name a constituent with no feed,
and pins the recipe in `governance/ops/<id>.json` so what executes after the delay is what was reviewed.

## Status

The v1 contracts are complete, with unit, fuzz, invariant and mainnet-fork coverage and an internal review. All 194
published Robinhood stock tokens can be listed; 35 carry a Chainlink feed and can be priced on-chain.
Baskets are curated by the protocol — `createBasket` is `onlyOwner`.

Governance runs through an OpenZeppelin `TimelockController`; redemption is deliberately outside it, so
holders can exit even if governance is captured. The quote service is built and tested but has not run
against a live deployment, and it does not yet quote Uniswap v4.

Still outstanding: an independent audit, a testnet rehearsal, v4 and RFQ coverage in the quoter, and a
front end.

Tokenized equities on Robinhood Chain are not available to US persons. Any front end must geo-block
accordingly, and the product needs legal review in every jurisdiction it serves.

## License

MIT
