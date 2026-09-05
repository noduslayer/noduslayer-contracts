# NodusLayer — Basket Protocol Design (v1)

Fully collateralised index baskets of Robinhood Chain stock tokens, with a single-transaction
zap that buys or sells the constituents through allow-listed routers. Robinhood Chain mainnet,
chain id 4663.

## Goals and non-goals

**Goals**

- Let a user hold a diversified basket of stock tokens as one ERC-20 that is always redeemable,
  in kind, for exactly what backs it.
- Make entry and exit one transaction at the best available execution, with routing decided
  off-chain and enforced on-chain (allow-list, exact output, minimum output, deadline).
- Keep the trust-minimised core small enough to audit in a day and impossible to pause.

**Non-goals for v1**

- On-chain rebalancing. Baskets are static recipes; a new weighting ships as a new basket plus
  a migration zap.
- A native protocol token. Fees accrue in basket shares and the zap's input/output token.
- Custodying anything between transactions. The zap refunds every leftover.

## Components

```
                      off-chain Quote Service (routes, splits, oracle sanity, calldata)
                                            │
   user ──token / ether──►   BasketZap  ────┼──► allow-listed routers (Uniswap SwapRouter02,
             ◄── shares ──   (Pausable)     │    UniversalRouter, 1inch, 0x …)
                                │ mint / redeem in kind
                                ▼
                          BasketToken (vault, immutable recipe, never pausable)
                                ▲
              BasketMigrator ───┤ moves holders between versions, trading only the difference
                                │
              BasketFactory ────┘ deploys, validates constituents against
                    │             StockRegistry, records official baskets, retires old ones
              StockRegistry ─── canonical stock-token addresses + Chainlink feeds
              BasketLens ────── read-only NAV / per-constituent quotes
```

| Contract | Owner | Mutable state after deployment |
|---|---|---|
| `StockRegistry` | protocol multisig (2-step) | listed set, feed per token |
| `BasketFactory` | protocol multisig | treasury, basket registry, retirement flags and successors |
| `BasketToken` | none — fee params governed by `factory.owner()` | fees within 1% cap, claims ledger |
| `BasketZap` | protocol multisig | router allow-list, fee ≤ 0.5%, treasury, paused flag |
| `BasketMigrator` | protocol multisig | router allow-list, paused flag |
| `BasketLens` | none | none |

## Recipe and units

A basket is `Constituent[] {token, units}` fixed at construction, 2–16 entries, unique tokens,
all listed in the registry at creation time. `units` is the constituent's base-unit amount that
backs `1e18` shares. Stock tokens are 18-decimal ERC-20s implementing ERC-8056: corporate actions
update `uiMultiplier()` instead of rebasing balances, so raw units are a total-return unit and a
recipe stays valid across splits and dividends without any vault logic.

## Mint and redeem

- `mint(shares, to)` pulls `ceil(shares · units_i / 1e18)` of each constituent from the caller,
  mints `shares − fee` to `to` and `fee` to the factory's treasury, read live. Fees are settled in
  shares so they stay backed. A retired basket refuses to mint.
- `redeem(shares, to)` moves `fee` shares to the fee recipient, burns the rest and pays
  `floor(net · units_i / 1e18)` of each constituent. It has no pause switch and touches no
  oracle or router.
- `redeemWithSkip(shares, to, skipMask)` is the escape hatch for a constituent the issuer has
  paused or block-listed: skipped legs are credited to `claimable[to][token]` instead of
  transferred, and collected later with `claim(token, to)`. All ledger writes happen before any
  token leaves the vault. `redeemWithSkipFor(shares, to, claimant, skipMask)` is the same for a
  contract acting on a holder's behalf: the paid legs go to `to`, the frozen leg is owed to
  `claimant`. The zap uses it so the claim lands with the holder, never with the zap.

**Backing invariant**, checked by fuzz tests for every constituent `i`:

```
balance_i · 1e18  ≥  totalSupply · units_i  +  totalClaimable_i · 1e18
```

Rounding is always in the vault's favour; dust accumulates in the vault and is never claimable.

## Zap

`zapMint(basket, tokenIn, amountIn, shares, swaps[], to, deadline)`:

1. Snapshot the zap's balance of every tracked token — the recipe, `tokenIn`, and each leg's
   sell token — then pull `amountIn`. Everything after this is measured against that snapshot.
2. Execute each `Swap {router, sellToken, prefund, data}`: router must be allow-listed;
   `sellToken` is approved for the duration of the call, and only for what this call has gained
   of it (optionally pre-transferred for routers that settle from their own balance, e.g.
   UniversalRouter v4 actions); approval is reset to zero afterwards.
3. Require the call gained at least `previewMint(shares)` of every constituent, mint to `to`.
4. Charge the fee on what the swaps spent — `amountIn` less what is left of it — and take it out
   of that remainder. The caller therefore sends the spend plus the fee on it, and the quote
   service sizes `amountIn` that way. Charging `amountIn` itself would tax the slippage allowance
   that comes back in the next step.
5. Refund every remaining constituent and the rest of `tokenIn` to the caller.

`zapMintWithPermit` takes an EIP-2612 `Permit {value, deadline, v, r, s}` in place of a prior
approval. The permit is spent in a `try`: anyone who has seen it can submit it first, and a
signature already used has already done its work, so the transfer that follows enforces the
allowance rather than the permit call. `zapMintETH(basket, shares, swaps[], to, deadline)` takes
ether, wraps it into the chain's WETH for the route and unwraps what was not spent; the WETH
address is a constructor argument, and only WETH may send ether to the zap.

`zapRedeem(basket, shares, tokenOut, minAmountOut, swaps[], to, deadline)` mirrors it: pull
shares, redeem in kind to the zap, execute legs, take the fee from what the legs produced of
`tokenOut`, require `amountOut ≥ minAmountOut`, pay `to`, refund unsold constituents.
`zapRedeemWithSkip(…, skipMask, …)` is the routed form of `redeemWithSkip`: the paid legs are
sold, the frozen leg is credited on the basket to `to`. `zapRedeemWithPermit` spends a permit on
the shares.

The zap only ever holds a caller's in-flight funds inside their own transaction, so malformed
routes can only cost their author. Because accounting is in deltas, a balance already sitting in
the contract can neither fund a mint nor be paid out as proceeds; `sweep` and `sweepEther` are
the only exits for it.

## Routing (off-chain, phase 2 service)

The Quote Service owns the graph of pools (Uniswap v2/v3/v4 + Rialto), quotes every candidate
route at the real trade size (Quoter contracts and RFQ APIs), tries splits, prices gas into the
objective, sanity-bounds the result with Chainlink, and encodes `Swap[]` calldata. The UI shows
one price from "our routing engine"; venue attribution lives in logs and documentation. Stock
feeds update 24/5, so the service must widen tolerances outside US market hours rather than
trust a stale feed against a 24/7 AMM.

## Constituent eligibility and weight caps

Every one of the 194 published Robinhood stock tokens is listed. `StockRegistry` requires only that a token
is a contract exposing `decimals()`; a Chainlink feed is optional and 159 of the 194 are listed with
`address(0)`.

That is sound because pricing is not on the critical path. `BasketToken` and `BasketZap` contain no oracle
reference at all: minting and redeeming move exact recipe amounts, and a zap is bounded by the caller's
`amountIn`, the per-constituent `InsufficientConstituent` check and `minAmountOut`. Only `BasketLens` reads a
feed. So a feed-less constituent costs on-chain NAV, not safety:

| Surface | Feed-less constituent |
|---|---|
| `mint` / `redeem` / `claim` | works |
| `zapMint` / `zapRedeem` | works |
| `createBasket` | works |
| `BasketLens.quotes` | returns the entry with `priced == false` |
| `BasketLens.nav` | reverts `NoFeed(token)` — never a partial sum |
| `script/CreateBasket.s.sol` | refuses, because it derives units from the feed |

`unpricedCount(basket)` reports how many constituents lack a price so a UI can label a basket rather than
discover the revert. Off-chain, `api.robinhood.com/rhj/prices` quotes all 194, so a front end can show value
for any basket; what a feed-less basket loses is *verifiable* on-chain NAV and composability with other
protocols.

Depth is not a gate either. It sets a per-token weight ceiling:

```
maxWeight_i = min(100%, depth_i x maxDepthShare / targetTrade)      (default: 1% and $5,000)
capacity    = min over i ( depth_i x maxDepthShare / weight_i )
```

`targetTradeUsd` is $5,000 — five times the largest realistic retail ticket. A basket's capacity is set by
its shallowest constituent, because a fixed recipe forces every purchase to buy `weight_i` of each token.
The cliff is real but only bites far above retail size: measured on the live USDG v3 pool, a $5,000 ASML buy
executes 0.30% over oracle while $20,000 executes 37.68% over. At $250 and $1,000 price impact is
immeasurable — NVDA quotes +0.01% at both.

Depth here is v4 PoolManager balances plus all USDG v2/v3 pools. That figure is wrong in both directions
and should be replaced by quote-derived capacity once the quoter covers v4.

It understates on one side: WETH-paired pools and RFQ liquidity are not counted at all, and several tokens
(ORCL, CRWV, CLSK, RGTI, IONQ, NBIS) trade $10-25M a day via RFQ on almost no AMM depth, so their caps are
far tighter than a quoter with RFQ access would need.

It overstates on the other, and an earlier version of this document had that backwards. The v4 PoolManager
is a singleton whose balance is spread across every pool it holds, and on this chain that is a very large
number of mostly worthless pools: NVDA alone has over 10,000 v4 pools, of which 224 pair against USDG and
only 45 carry no hook, with fee tiers running up to 99% and the dynamic-fee flag. Attributing the whole
singleton balance to reachable depth credits a constituent with liquidity no trade can touch. Quoting v4
safely needs a persistent `Initialize` indexer and a hook allow-list, which `services/quoter` does not yet
have; until then its numbers cover v2 and v3 only.

`config/baskets/*.json` declares **target weights**, not raw units. `script/CreateBasket.s.sol` reads live
Chainlink prices at creation, derives `units`, and rejects any recipe whose weights breach a cap, fall below
the 1% floor, fail to sum to 100%, or name a constituent with no feed.

## Fees

| Fee | Where | Cap | Default |
|---|---|---|---|
| mint | shares minted to the factory's treasury | 1.00% | 0.10% |
| redeem | shares transferred to the factory's treasury | 1.00% | 0.10% |
| zap mint | `tokenIn`, on what the swaps spent, to the zap's treasury | 0.50% | 0.20% |
| zap redeem | `tokenOut`, on what the swaps produced, to the zap's treasury | 0.50% | 0.20% |
| migrate | none — the two baskets' redeem and mint fees already apply | — | — |

Baskets read the treasury from the factory rather than storing their own, so moving it is one
governance action for every basket. `setFees(mintFeeBps, redeemFeeBps)` on a basket is callable by
the factory's owner only.

## Versioning (option C)

A recipe is immutable, so a rebalance is a new `BasketToken` with new weights. `BasketMigrator` moves a
holder across in one transaction: it redeems the old basket in kind, trades only the legs that changed, and
mints the new one. Constituents both versions hold never leave the contract, so a rebalance that swaps one
name out of a five-name basket pays spread on that one name rather than on all five.

It charges no fee of its own — the two baskets already take a redeem fee on the way out and a mint fee on
the way in, and a third would tax holders for following a rebalance the protocol asked them to make.
Holders who do not migrate keep a fully backed old basket; nothing expires.

`BasketZap` and `BasketMigrator` share `RouteExecutor`, which owns the router allow-list and the delta
accounting. That code decides what a call may spend and refund, so keeping one copy is what stops a fix
from landing on one contract and not the other. Each deployment keeps its own allow-list: sharing one would
let a paused or replaced peer disable routing everywhere.

## Retirement

`BasketFactory.retire(basket, successor)` marks a basket the protocol has moved on from. From then on it
takes no new shares — `mint` reverts with `Retired`, the zap and the migrator refuse it as a destination
with `BasketRetired` — while `redeem`, `redeemWithSkip`, `claim`, the zap's exits and migrating *out of*
it stay open forever. `successor` names the basket holders should migrate to, or is zero; it must be a
live basket other than the one retiring. Retirement is not reversible: a basket worth reviving is worth a
new deployment. The state is public (`isRetired`, `successorOf`, `BasketRetired`), so a front end or the
quote service can steer holders without a trusted list.

## Chain facts relied upon

- Stock tokens: 18 decimals, freely transferable to contracts, `BeaconProxy` behind a shared
  beacon; issuer can `pause`, block-list (`isBlocked`), `mint` and `burn(address,uint256)`.
- USDG has 6 decimals; WETH 18.
- Chainlink feeds: 8 decimals, 24h heartbeat, 0.5% deviation, `us_equities_24/5`.
- Uniswap deployments per `Uniswap/contracts/deployments/4663.md`; SwapRouter02 pulls via
  `transferFrom`, UniversalRouter v4 settles via Permit2 or router balance (`prefund`).

See `docs/audit/2026-09-04-internal-review.md` for the threat model and review findings.
