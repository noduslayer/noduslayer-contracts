# Basket catalogue

15 curated baskets. The protocol creates and owns all of them: `BasketFactory.createBasket` is
`onlyOwner`, so users cannot deploy their own.

`test/fork/BasketCatalogue.t.sol` deploys every basket in this catalogue against Robinhood Chain mainnet
using live Chainlink prices, and asserts that each constituent has a feed, weights sum to 100%, no weight
breaches its depth cap, and `BasketLens.nav` lands within 1% of the target NAV. A broken recipe fails the
test rather than reaching production.

Specs declare **target weights**, not raw units. Units are derived from Chainlink at creation, so a stale
spec cannot ship a mispriced recipe.

- **Capacity** is the largest single purchase before any constituent absorbs more than 1% of its
  depth: `min(depth_i x 1% / weight_i)`. The constituent with the lowest depth-to-weight ratio sets it, which is not always the shallowest one.
- **Gas** estimates a steady-state `zapMint` at roughly $0.34 plus $0.22 per constituent.

The catalogue is fifteen of the sixty recipes drafted. Thirty were kept on 2026-09-06 for the testnet
rehearsal, and the launch set was cut to fifteen the same day: every theme keeps at least one basket, the
deepest recipe of each near-duplicate group survives (TECH into MAG7, CLOUD into DATA, VALUE into GROWTH,
BAL into SIXTY40 and ALLW, CMDTY into INFL, the four meme recipes into DIAMOND), and the rest were ranked
by capacity. The retired specs stay in the repository history as candidates for later; on testnet they
exist as retired baskets.

## Core and broad market

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Broad Market | `BROAD` | SPY 60% / QQQ 40% | $77,390 | $0.78 |
| Magnificent Seven | `MAG7` | NVDA 20% / AAPL 15% / MSFT 15% / GOOGL 15% / AMZN 15% / META 12% / TSLA 8% | $51,783 | $1.88 |

## AI and semiconductors

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| AI | `AI` | NVDA 30% / AMD 20% / TSM 20% / MU 15% / PLTR 15% | $27,298 | $1.44 |
| Semiconductors | `SEMI` | NVDA 30% / TSM 20% / AMD 20% / MU 15% / ASML 10% / INTC 5% | $19,227 | $1.66 |
| GPU Duopoly | `GPU` | NVDA 60% / AMD 40% | $13,649 | $0.78 |

## Software, cloud and data

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Data & Analytics | `DATA` | PLTR 45% / MSFT 30% / NVDA 25% | $17,143 | $1.00 |
| Digital Ads | `ADS` | GOOGL 50% / META 50% | $12,428 | $0.78 |

## Crypto and fintech

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Crypto Equities | `CRYPTOEQ` | MSTR 40% / COIN 35% / CRCL 25% | $10,831 | $1.00 |

## Frontier and space

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Space | `SPACE` | SPCX 85% / RKLB 15% | $5,617 | $0.78 |

## Style and factor

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Growth | `GROWTH` | NVDA 30% / PLTR 25% / CRCL 25% / MSTR 20% | $30,857 | $1.22 |

## Allocation and defensive

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| 60/40 | `SIXTY40` | SPY 60% / SGOV 40% | $21,824 | $0.78 |
| All Weather | `ALLW` | SPY 35% / SGOV 30% / SLV 20% / USO 15% | $19,062 | $1.22 |

## Commodities and materials

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Inflation Hedge | `INFL` | SLV 40% / USO 30% / USAR 30% | $6,925 | $1.00 |

## Geography and consumer

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| EV & Autonomy | `EV` | TSLA 60% / NVDA 40% | $27,677 | $0.78 |

## Meme and retail culture

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Diamond Hands | `DIAMOND` | GME 35% / MSTR 30% / TSLA 20% / PLTR 15% | $34,125 | $1.22 |

## Constraints that shaped the catalogue

Depth caps changed composition rather than merely rubber-stamping it:

| Token | Depth | Max weight |
|---|--:|--:|
| `NBIS` | $22,143 | 4.42% |
| `IONQ` | $23,025 | 4.60% |
| `CLSK` | $23,548 | 4.70% |
| `RGTI` | $26,542 | 5.30% |
| `EWY` | $30,078 | 6.01% |
| `CRWV` | $41,604 | 8.32% |
| `ORCL` | $43,048 | 8.60% |
| `RKLB` | $84,251 | 16.85% |
| `ASML` | $192,266 | 38.45% |
| `USAR` | $207,749 | 41.54% |
| `COIN` | $379,075 | 75.81% |
| `SLV` | $381,247 | 76.24% |
| `INTC` | $383,615 | 76.72% |
| `BABA` | $403,901 | 80.78% |
| `SNDK` | $499,319 | 99.86% |

- A pure quantum basket is arithmetically impossible: IONQ (4.60%), RGTI (5.30%) and CLSK (4.70%)
  together cannot reach 15% weight, so `QNTM` anchors on NVDA.
- EWY (6.01%) is the shallowest constituent in the catalogue and sets the lowest capacity: `ASIA` at
  $5,013.
- ORCL is capped at 8.60% despite roughly $25M a day of RFQ volume, because its AMM depth is only $43,048;
  it holds `CLOUD` to $5,381 per trade.

The lowest capacity in the catalogue is $5,013 (`ASIA`), above the $5,000 target trade the policy sizes for.

## Creating a basket

```sh
cd contracts
export FACTORY=0x... TIMELOCK=0x... MULTISIG=0x...
BASKETS=tech,ai MODE=schedule forge script script/CreateBasket.s.sol --rpc-url robinhood --sender $MULTISIG
# submit the printed transaction from the multisig; after the delay, MODE=execute OP=<id>
```

Adding a basket means adding one file under `config/baskets/`. The factory belongs to the timelock, so
creation is scheduled and executed after the delay, up to ten baskets per operation. The script and the fork
test both reject a recipe whose weights do not sum to 100%, breach a depth cap, fall below the 1% floor, or
name a constituent with no Chainlink feed.

Depth snapshot 2026-09-04T06:16:20+00:00. It counts USDG
v2/v3 pools and v4 PoolManager balances only, so it is a lower bound. Recompute before adding baskets.
