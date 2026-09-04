# Basket catalogue

60 curated baskets. The protocol creates and owns all of them: `BasketFactory.createBasket` is
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

## Core and broad market

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Broad Market | `BROAD` | SPY 60% / QQQ 40% | $77,390 | $0.78 |
| S&P Tilt | `SPTILT` | SPY 80% / QQQ 20% | $90,346 | $0.78 |
| Nasdaq Tilt | `QTILT` | QQQ 80% / SPY 20% | $38,695 | $0.78 |
| Core 5 | `CORE5` | NVDA 25% / AAPL 20% / MSFT 20% / GOOGL 20% / AMZN 15% | $51,381 | $1.44 |
| Equal-Weight Tech | `EQTECH` | NVDA 20% / AAPL 20% / MSFT 20% / GOOGL 20% / META 20% | $31,069 | $1.44 |
| Concentrated Trio | `TRIO` | NVDA 40% / MSFT 30% / AAPL 30% | $34,254 | $1.00 |
| Tech | `TECH` | NVDA 30% / AAPL 25% / GOOGL 25% / MSFT 20% | $51,381 | $1.22 |
| Magnificent Seven | `MAG7` | NVDA 20% / AAPL 15% / MSFT 15% / GOOGL 15% / AMZN 15% / META 12% / TSLA 8% | $51,782 | $1.88 |

## AI and semiconductors

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| AI | `AI` | NVDA 30% / AMD 20% / TSM 20% / MU 15% / PLTR 15% | $27,298 | $1.44 |
| Semiconductors | `SEMI` | NVDA 30% / TSM 20% / AMD 20% / MU 15% / ASML 10% / INTC 5% | $19,227 | $1.66 |
| AI Infrastructure | `AIINF` | NVDA 30% / MU 25% / DELL 20% / SNDK 15% / CRWV 8% / NBIS 2% | $5,200 | $1.66 |
| GPU Duopoly | `GPU` | NVDA 60% / AMD 40% | $13,649 | $0.78 |
| Foundry | `FNDRY` | TSM 50% / ASML 30% / INTC 20% | $6,409 | $1.00 |
| Memory & Storage | `MEM` | MU 50% / SNDK 50% | $9,986 | $0.78 |
| Chip Equipment | `CHIPEQ` | ASML 35% / TSM 35% / INTC 30% | $5,493 | $1.00 |
| Global Semis | `GSEMI` | TSM 35% / NVDA 25% / ASML 25% / AMD 15% | $7,691 | $1.22 |
| AI Cloud | `AICLD` | NVDA 50% / MU 20% / DELL 18% / CRWV 8% / NBIS 4% | $5,200 | $1.44 |

## Software, cloud and data

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Cloud | `CLOUD` | MSFT 40% / GOOGL 30% / PLTR 22% / ORCL 8% | $5,381 | $1.22 |
| Data & Analytics | `DATA` | PLTR 45% / MSFT 30% / NVDA 25% | $17,143 | $1.00 |
| Enterprise IT | `ENTIT` | MSFT 35% / DELL 32% / INTC 25% / ORCL 8% | $5,381 | $1.22 |
| Digital Ads | `ADS` | GOOGL 50% / META 50% | $12,428 | $0.78 |

## Crypto and fintech

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Crypto Equities | `CRYPTOEQ` | MSTR 40% / COIN 35% / CRCL 25% | $10,831 | $1.00 |
| Bitcoin Proxy | `BTCPX` | MSTR 55% / COIN 41% / CLSK 4% | $5,887 | $1.00 |
| Fintech | `FINTECH` | CRCL 50% / COIN 50% | $7,582 | $0.78 |

## Frontier and space

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Frontier Tech | `FRNT` | NVDA 60% / RKLB 15% / CRWV 8% / RGTI 5% / CLSK 4% / IONQ 4% / NBIS 4% | $5,200 | $1.88 |
| Quantum & Emerging | `QNTM` | NVDA 70% / CRWV 8% / RGTI 5% / RKLB 5% / IONQ 4% / CLSK 4% / NBIS 4% | $5,200 | $1.88 |
| Space | `SPACE` | SPCX 85% / RKLB 15% | $5,617 | $0.78 |
| New Space | `NSPACE` | SPCX 70% / RKLB 16% / NVDA 14% | $5,266 | $1.00 |

## Style and factor

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Growth | `GROWTH` | NVDA 30% / PLTR 25% / CRCL 25% / MSTR 20% | $30,857 | $1.22 |
| Value | `VALUE` | INTC 32% / BABA 32% / DELL 28% / ORCL 8% | $5,381 | $1.22 |
| Momentum | `MOM` | MSTR 35% / PLTR 30% / CRCL 19% / RKLB 16% | $5,266 | $1.22 |

## Allocation and defensive

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Balanced | `BAL` | SPY 40% / SGOV 30% / NVDA 20% / SLV 10% | $29,098 | $1.22 |
| 60/40 | `SIXTY40` | SPY 60% / SGOV 40% | $21,824 | $0.78 |
| All Weather | `ALLW` | SPY 35% / SGOV 30% / SLV 20% / USO 15% | $19,062 | $1.22 |
| Cash Plus | `CASHP` | SGOV 80% / SPY 20% | $10,912 | $0.78 |
| Low Volatility | `LOWVOL` | SGOV 60% / SPY 25% / SLV 15% | $14,549 | $1.00 |
| Defensive | `DEF` | SGOV 50% / SLV 30% / USO 20% | $12,708 | $1.00 |

## Commodities and materials

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Commodities | `CMDTY` | SLV 60% / USO 40% | $6,354 | $0.78 |
| Inflation Hedge | `INFL` | SLV 40% / USO 30% / USAR 30% | $6,925 | $1.00 |
| Metals | `METAL` | SLV 60% / USAR 40% | $5,194 | $0.78 |

## Geography and consumer

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Asia Tech | `ASIA` | TSM 50% / BABA 44% / EWY 6% | $5,013 | $1.00 |
| China Exposure | `CHINA` | BABA 74% / TSM 20% / EWY 6% | $5,013 | $1.00 |
| Consumer | `CONS` | AMZN 35% / TSLA 30% / BABA 25% / GME 10% | $16,156 | $1.22 |
| Retail | `RETAIL` | GME 40% / AMZN 35% / TSLA 25% | $29,389 | $1.00 |
| Hardware | `HDWR` | AAPL 40% / DELL 30% / SNDK 30% | $16,644 | $1.00 |
| EV & Autonomy | `EV` | TSLA 60% / NVDA 40% | $27,677 | $0.78 |
| Legacy Tech | `LEGACY` | INTC 35% / DELL 30% / BABA 27% / ORCL 8% | $5,381 | $1.22 |

## Meme and retail culture

| Basket | Symbol | Composition | Capacity/tx | Gas |
|---|---|---|--:|--:|
| Gigachad | `GIGA` | NVDA 30% / GOOGL 25% / AAPL 25% / INTC 15% / GME 5% | $25,574 | $1.44 |
| Diamond Hands | `DIAMOND` | GME 35% / MSTR 30% / TSLA 20% / PLTR 15% | $34,125 | $1.22 |
| Paper Hands | `PAPER` | SGOV 70% / SPY 20% / SLV 10% | $12,471 | $1.00 |
| To The Moon | `MOON` | SPCX 60% / NVDA 24% / RKLB 16% | $5,266 | $1.00 |
| Stonks Only Go Up | `STONKS` | GME 30% / TSLA 25% / MSTR 25% / COIN 20% | $18,954 | $1.22 |
| HODL | `HODL` | MSTR 41% / COIN 35% / CRCL 20% / CLSK 4% | $5,887 | $1.22 |
| Boomer Tech | `BOOMER` | INTC 35% / DELL 32% / BABA 25% / ORCL 8% | $5,381 | $1.22 |
| Zoomer Tech | `ZOOMER` | PLTR 35% / MSTR 25% / CRCL 20% / RKLB 16% / IONQ 4% | $5,266 | $1.44 |
| Skynet | `SKYNET` | NVDA 55% / PLTR 20% / CRWV 8% / RGTI 5% / IONQ 4% / NBIS 4% / CLSK 4% | $5,200 | $1.88 |
| Tendies | `TENDIES` | GME 30% / AMZN 30% / TSLA 25% / COIN 15% | $25,272 | $1.22 |
| Buy The Dip | `BTD` | INTC 40% / BABA 35% / DELL 25% | $9,590 | $1.00 |
| YOLO | `YOLO` | MSTR 55% / GME 45% | $18,614 | $0.78 |
| Touch Grass | `GRASS` | SPY 50% / SGOV 30% / SLV 20% | $19,062 | $1.00 |

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

- A pure quantum basket is arithmetically impossible. IONQ (4.60%), RGTI
  (5.30%) and CLSK (4.70%) together cannot reach 15% weight, so `QNTM`,
  `FRNT` and `SKYNET` anchor on NVDA.
- EWY (6.01%) is the shallowest constituent in the catalogue and sets the lowest capacity:
  `ASIA` at $5,013.
- ORCL is capped at 8.60% despite roughly $25M a day of RFQ volume, because its AMM depth
  is only $43,048.

The lowest capacity in the catalogue is $5,013, five times the largest expected retail ticket.

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
