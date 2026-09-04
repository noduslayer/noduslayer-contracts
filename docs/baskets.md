# NodusLayer — Katalog Basket

**47 basket kurasi.** Semua dibuat dan dikelola protokol: `BasketFactory.createBasket` bersifat
`onlyOwner`, jadi pengguna tidak bisa membuat basket sendiri.

Seluruh katalog diuji terhadap Robinhood Chain mainnet (chain 4663) oleh
`test/fork/BasketCatalogue.t.sol`, yang benar-benar men-deploy setiap basket dengan harga Chainlink live dan
memastikan: semua konstituen punya feed on-chain, bobot berjumlah 100%, tidak ada yang melanggar cap
kedalaman, dan `BasketLens.nav` mengembalikan nilai dalam 1% dari target. Resep yang rusak menggagalkan tes.

Spesifikasi menyatakan **bobot**, bukan `units`; `units` diturunkan dari Chainlink saat pembuatan sehingga
spec basi tidak bisa menghasilkan resep salah harga.

- **Kapasitas** — pembelian sekali transaksi terbesar sebelum satu konstituen menyerap lebih dari
  1% kedalamannya: `min(kedalaman_i × 1% ÷ bobot_i)`. Ditentukan konstituen **terdangkal**.
- **Gas** — perkiraan zapMint kondisi mapan, ~$0.34 + $0.22 per konstituen.

## Inti & pasar luas

| Basket | Simbol | Komposisi | Kapasitas/tx | Gas |
|---|---|---|--:|--:|
| Broad Market | `BROAD` | SPY 60% · QQQ 40% | $77,390 | $0.78 |
| S&P Tilt | `SPTILT` | SPY 80% · QQQ 20% | $90,346 | $0.78 |
| Nasdaq Tilt | `QTILT` | QQQ 80% · SPY 20% | $38,695 | $0.78 |
| Core 5 | `CORE5` | NVDA 25% · AAPL 20% · MSFT 20% · GOOGL 20% · AMZN 15% | $51,381 | $1.44 |
| Equal-Weight Tech | `EQTECH` | NVDA 20% · AAPL 20% · MSFT 20% · GOOGL 20% · META 20% | $31,069 | $1.44 |
| Concentrated Trio | `TRIO` | NVDA 40% · MSFT 30% · AAPL 30% | $34,254 | $1.00 |
| Tech | `TECH` | NVDA 30% · AAPL 25% · GOOGL 25% · MSFT 20% | $51,381 | $1.22 |
| Magnificent Seven | `MAG7` | NVDA 20% · AAPL 15% · MSFT 15% · GOOGL 15% · AMZN 15% · META 12% · TSLA 8% | $51,782 | $1.88 |

## AI & semikonduktor

| Basket | Simbol | Komposisi | Kapasitas/tx | Gas |
|---|---|---|--:|--:|
| AI | `AI` | NVDA 30% · AMD 20% · TSM 20% · MU 15% · PLTR 15% | $27,298 | $1.44 |
| Semiconductors | `SEMI` | NVDA 30% · TSM 20% · AMD 20% · MU 15% · ASML 10% · INTC 5% | $19,227 | $1.66 |
| AI Infrastructure | `AIINF` | NVDA 30% · MU 25% · DELL 20% · SNDK 15% · CRWV 8% · NBIS 2% | $5,200 | $1.66 |
| GPU Duopoly | `GPU` | NVDA 60% · AMD 40% | $13,649 | $0.78 |
| Foundry | `FNDRY` | TSM 50% · ASML 30% · INTC 20% | $6,409 | $1.00 |
| Memory & Storage | `MEM` | MU 50% · SNDK 50% | $9,986 | $0.78 |
| Chip Equipment | `CHIPEQ` | ASML 35% · TSM 35% · INTC 30% | $5,493 | $1.00 |
| Global Semis | `GSEMI` | TSM 35% · NVDA 25% · ASML 25% · AMD 15% | $7,691 | $1.22 |
| AI Cloud | `AICLD` | NVDA 50% · MU 20% · DELL 18% · CRWV 8% · NBIS 4% | $5,200 | $1.44 |

## Perangkat lunak, cloud & data

| Basket | Simbol | Komposisi | Kapasitas/tx | Gas |
|---|---|---|--:|--:|
| Cloud | `CLOUD` | MSFT 40% · GOOGL 30% · PLTR 22% · ORCL 8% | $5,381 | $1.22 |
| Data & Analytics | `DATA` | PLTR 45% · MSFT 30% · NVDA 25% | $17,143 | $1.00 |
| Enterprise IT | `ENTIT` | MSFT 35% · DELL 32% · INTC 25% · ORCL 8% | $5,381 | $1.22 |
| Digital Ads | `ADS` | GOOGL 50% · META 50% | $12,428 | $0.78 |

## Kripto & fintech

| Basket | Simbol | Komposisi | Kapasitas/tx | Gas |
|---|---|---|--:|--:|
| Crypto Equities | `CRYPTOEQ` | MSTR 40% · COIN 35% · CRCL 25% | $10,831 | $1.00 |
| Bitcoin Proxy | `BTCPX` | MSTR 55% · COIN 41% · CLSK 4% | $5,887 | $1.00 |
| Fintech | `FINTECH` | CRCL 50% · COIN 50% | $7,582 | $0.78 |

## Frontier & antariksa

| Basket | Simbol | Komposisi | Kapasitas/tx | Gas |
|---|---|---|--:|--:|
| Frontier Tech | `FRNT` | NVDA 60% · RKLB 15% · CRWV 8% · RGTI 5% · CLSK 4% · IONQ 4% · NBIS 4% | $5,200 | $1.88 |
| Quantum & Emerging | `QNTM` | NVDA 70% · CRWV 8% · RGTI 5% · RKLB 5% · IONQ 4% · CLSK 4% · NBIS 4% | $5,200 | $1.88 |
| Space | `SPACE` | SPCX 85% · RKLB 15% | $5,617 | $0.78 |
| New Space | `NSPACE` | SPCX 70% · RKLB 16% · NVDA 14% | $5,266 | $1.00 |

## Gaya & faktor

| Basket | Simbol | Komposisi | Kapasitas/tx | Gas |
|---|---|---|--:|--:|
| Growth | `GROWTH` | NVDA 30% · PLTR 25% · CRCL 25% · MSTR 20% | $30,857 | $1.22 |
| Value | `VALUE` | INTC 32% · BABA 32% · DELL 28% · ORCL 8% | $5,381 | $1.22 |
| Momentum | `MOM` | MSTR 35% · PLTR 30% · CRCL 19% · RKLB 16% | $5,266 | $1.22 |

## Alokasi & defensif

| Basket | Simbol | Komposisi | Kapasitas/tx | Gas |
|---|---|---|--:|--:|
| Balanced | `BAL` | SPY 40% · SGOV 30% · NVDA 20% · SLV 10% | $29,098 | $1.22 |
| 60/40 | `SIXTY40` | SPY 60% · SGOV 40% | $21,824 | $0.78 |
| All Weather | `ALLW` | SPY 35% · SGOV 30% · SLV 20% · USO 15% | $19,062 | $1.22 |
| Cash Plus | `CASHP` | SGOV 80% · SPY 20% | $10,912 | $0.78 |
| Low Volatility | `LOWVOL` | SGOV 60% · SPY 25% · SLV 15% | $14,549 | $1.00 |
| Defensive | `DEF` | SGOV 50% · SLV 30% · USO 20% | $12,708 | $1.00 |

## Komoditas & material

| Basket | Simbol | Komposisi | Kapasitas/tx | Gas |
|---|---|---|--:|--:|
| Commodities | `CMDTY` | SLV 60% · USO 40% | $6,354 | $0.78 |
| Inflation Hedge | `INFL` | SLV 40% · USO 30% · USAR 30% | $6,925 | $1.00 |
| Metals | `METAL` | SLV 60% · USAR 40% | $5,194 | $0.78 |

## Geografi & konsumen

| Basket | Simbol | Komposisi | Kapasitas/tx | Gas |
|---|---|---|--:|--:|
| Asia Tech | `ASIA` | TSM 50% · BABA 44% · EWY 6% | $5,013 | $1.00 |
| China Exposure | `CHINA` | BABA 74% · TSM 20% · EWY 6% | $5,013 | $1.00 |
| Consumer | `CONS` | AMZN 35% · TSLA 30% · BABA 25% · GME 10% | $16,156 | $1.22 |
| Retail | `RETAIL` | GME 40% · AMZN 35% · TSLA 25% | $29,389 | $1.00 |
| Hardware | `HDWR` | AAPL 40% · DELL 30% · SNDK 30% | $16,644 | $1.00 |
| EV & Autonomy | `EV` | TSLA 60% · NVDA 40% | $27,677 | $0.78 |
| Legacy Tech | `LEGACY` | INTC 35% · DELL 30% · BABA 27% · ORCL 8% | $5,381 | $1.22 |

## Batasan yang membentuk katalog

Cap kedalaman bukan formalitas — ia mengubah komposisi. Cap yang mengikat saat ini:

| Token | Kedalaman | Bobot maks |
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

Konsekuensi nyata:

- **Basket kuantum murni mustahil.** IONQ (4.60%), RGTI (5.30%) dan
  CLSK (4.70%) digabung pun tak mencapai 15% bobot. `QNTM` dan `FRNT` memakai NVDA sebagai
  jangkar agar kapasitasnya layak.
- **ASML** (38.45%) membatasi `SEMI` ke 10% dan `CHIPEQ` ke 35%.
- **EWY** (6.01%) adalah konstituen terdangkal di katalog dan menentukan kapasitas
  `ASIA` ($5,013).
- **ORCL** dibatasi 8.60% meski volume RFQ-nya ~$25 juta/hari, karena kedalaman AMM-nya
  hanya $43,048.

Kapasitas terkecil di katalog adalah $5,013 — lima kali lipat tiket ritel terbesar yang
diperkirakan (~$1.000).

## Membuat basket

```sh
cd contracts
export FACTORY=0x...
BASKET=tech forge script script/CreateBasket.s.sol --rpc-url robinhood --account owner --broadcast
```

Menambah basket = menambah satu file di `config/baskets/`. Script dan fork test menolak resep yang bobotnya
tidak berjumlah 100%, melanggar cap kedalaman, jatuh di bawah lantai 1%,
atau memuat konstituen tanpa feed Chainlink.

Snapshot kedalaman 2026-09-04T09:07:24+00:00; hanya
menghitung pool USDG v2/v3 dan saldo v4 PoolManager, sehingga merupakan **batas bawah**. Likuiditas
bergerak — hitung ulang cap sebelum menambah basket.
