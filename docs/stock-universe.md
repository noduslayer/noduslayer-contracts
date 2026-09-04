# Robinhood Chain — Semesta Token Saham

Snapshot 2026-09-04T07:05:50+00:00 · chain 4663 · **194 token saham/ETF, semua `ASSET_STATUS_ACTIVE`**.

Sumber: [`api.robinhood.com/rhj/assets`](https://docs.robinhood.com/chain/stock-token-apis) (registry aset on-chain),
`/rhj/prices` (bid/ask/volume RFQ), [direktori feed Chainlink](https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood).
Kedalaman diukur langsung via Multicall3: saldo token di v4 PoolManager + seluruh pool USDG v2/v3.
Angka ini **batas bawah** — pasangan WETH/saham-lain dan likuiditas RFQ tidak terhitung.

## Angka kunci

| | |
|---|--:|
| Token saham terdaftar | **194** |
| Punya Chainlink feed → **eligible sebagai konstituen** | **35** |
| Tanpa feed (terblokir) | 159 |
| Bobot maks ≥ 1% (layak dipakai nyata) | **28** |
| Total kedalaman on-chain | $83,694,136 |
| Total volume RFQ 24 jam | $2,622,644,204 |
| Trading halt | SOUN |

`multiplier != 1.0` (aksi korporasi ERC-8056 sudah terjadi): MU 1.00007, AAPL 1.00057, COST 1.00061, SGOV 1.0051, DELL 1.00006, ASML 1.0001, F 1.00015, CCL 1.02149, ORCL 1.00221, CRWD 4

## Kebijakan bobot

Kedalaman **bukan gerbang lolos/tidak**, melainkan penentu **bobot maksimum**:

```
bobot_maks = min(100%, kedalaman × 1% / $50,000)
```

Artinya: satu zap sebesar $50,000 tidak boleh mengambil lebih dari 1% kedalaman konstituen mana pun.
Kapasitas basket ditentukan konstituen **terdangkal**, bukan rata-rata:
`kapasitas = min(kedalaman_i × 1% / bobot_i)`.

Ini heuristik, bukan jaminan — konsentrasi likuiditas v3 berbeda tiap pool. Verifikasi akhir selalu lewat quote sungguhan.
Diterapkan oleh `script/CreateBasket.s.sol`, yang menolak resep yang melanggarnya.

Bukti terukur (QuoterV2, pool USDG v3, 2026-09-04):

| Token | Beli $5.000 | Beli $20.000 |
|---|--:|--:|
| NVDA ($12,332,411) | −0,13% | −0,11% |
| MSFT ($1,027,615) | — | +0,89% |
| ASML ($192,266) | +0,30% | **+37,68%** |
| USAR, EWY, RKLB | revert | revert |

## Konstituen eligible (35 token ber-feed, urut kedalaman)

| # | Simbol | Nama | Kedalaman | Vol 24j | Bobot maks | Alamat |
|--:|---|---|--:|--:|--:|---|
| 1 | `NVDA` | NVIDIA | $12,332,411 | $134,681,610 | 100.00% | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| 2 | `SPY` | SPDR S&P 500 ETF Trust | $7,227,703 | $43,531,466 | 100.00% | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` |
| 3 | `SPCX` | Space Exploration Technologies C | $4,533,323 | $121,333,531 | 90.66% | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` |
| 4 | `MU` | Micron Technology | $3,368,614 | $24,175,723 | 67.37% | `0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD` |
| 5 | `QQQ` | Invesco QQQ | $3,095,612 | $29,449,629 | 61.91% | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` |
| 6 | `AAPL` | Apple | $2,107,345 | $37,225,806 | 42.14% | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` |
| 7 | `GME` | GameStop | $1,945,718 | $7,226,765 | 38.91% | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` |
| 8 | `TSLA` | Tesla | $1,660,646 | $63,600,988 | 33.21% | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` |
| 9 | `GOOGL` | Alphabet Class A | $1,515,880 | $20,726,615 | 30.31% | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` |
| 10 | `CRCL` | Circle Internet Group | $1,373,899 | $24,733,421 | 27.47% | `0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5` |
| 11 | `TSM` | Taiwan Semiconductor Manufacturi | $1,257,982 | $7,827,652 | 25.15% | `0x58FfE4a942d3885bAa22D7520691F611EF09e7AA` |
| 12 | `AMZN` | Amazon | $1,028,609 | $26,891,496 | 20.57% | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` |
| 13 | `MSFT` | Microsoft | $1,027,615 | $24,125,540 | 20.55% | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` |
| 14 | `MSTR` | Strategy Inc. | $1,023,758 | $45,245,416 | 20.47% | `0xec262a75e413fAfD0dF80480274532C79D42da09` |
| 15 | `SGOV` | iShares 0-3 Month Treasury Bond | $872,946 | $21,303,339 | 17.45% | `0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5` |
| 16 | `USO` | United States Oil Fund | $808,005 | $4,036,628 | 16.16% | `0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344` |
| 17 | `PLTR` | Palantir Technologies | $771,413 | $38,107,977 | 15.42% | `0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A` |
| 18 | `DELL` | Dell | $629,926 | $20,327,940 | 12.59% | `0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd` |
| 19 | `META` | Meta Platforms | $621,390 | $19,737,139 | 12.42% | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` |
| 20 | `AMD` | AMD | $545,953 | $14,867,890 | 10.91% | `0x86923f96303D656E4aa86D9d42D1e57ad2023fdC` |
| 21 | `SNDK` | Sandisk Corporation | $499,319 | $8,688,931 | 9.98% | `0xB90A19fF0Af67f7779afF50A882A9CfF42446400` |
| 22 | `BABA` | Alibaba | $403,901 | $8,602,290 | 8.07% | `0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4` |
| 23 | `INTC` | Intel | $383,615 | $79,927,772 | 7.67% | `0xc72b96e0E48ecd4DC75E1e45396e26300BC39681` |
| 24 | `SLV` | iShares Silver Trust | $381,247 | $13,837,399 | 7.62% | `0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f` |
| 25 | `COIN` | Coinbase | $379,075 | $13,741,513 | 7.58% | `0x6330D8C3178a418788dF01a47479c0ce7CCF450b` |
| 26 | `USAR` | USA Rare Earth | $207,749 | $7,547,309 | 4.15% | `0xd917B029C761D264c6A312BBbcDA868658eF86a6` |
| 27 | `ASML` | ASML Holding NV | $192,266 | $1,439,231 | 3.84% | `0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA` |
| 28 | `RKLB` | Rocket Lab Corporation | $84,251 | $18,913,089 | 1.68% | `0x3b14C39E89D60D627b42a1A4CA45b5bb45Fc12e2` |
| 29 | `ORCL` | Oracle | $43,048 | $25,101,700 | 0.86% | `0xb0992820E760d836549ba69BC7598b4af75dEE03` |
| 30 | `CRWV` | CoreWeave | $41,604 | $18,798,407 | 0.83% | `0x5f10A1C971B69e47e059e1dC91901B59b3fB49C3` |
| 31 | `EWY` | iShares MSCI South Korea fund | $30,078 | $10,934,363 | 0.60% | `0x7f0aBeF0C07280F82c6a08ead09dEd6BAE2C13Fc` |
| 32 | `RGTI` | Rigetti Computing | $26,542 | $14,140,597 | 0.53% | `0x284358abc07F9359f19f4b5b4aC91901Be2597Ba` |
| 33 | `CLSK` | CleanSpark | $23,548 | $23,533,915 | 0.47% | `0xcBB95BBF36099d34dA091dc6Fa6F49EfA257Cee3` |
| 34 | `IONQ` | IonQ | $23,025 | $14,009,182 | 0.46% | `0x558378E000D634A36593E338eBacdd6207640EfE` |
| 35 | `NBIS` | Nebius Group | $22,143 | $10,679,503 | 0.44% | `0x9D9c6684F596F66a64C030B93A886D51Fd4D7931` |

## Terblokir: tanpa Chainlink feed (159 token)

Vault sebenarnya tidak butuh oracle — `mint`/`redeem` in-kind tidak pernah menyentuhnya. Yang hilang tanpa feed
adalah tampilan NAV dan pagar oracle pada zap, sehingga `StockRegistry` menolaknya. Beberapa di antaranya sangat dalam:

| # | Simbol | Nama | Kedalaman | Vol 24j | Feed | Alamat |
|--:|---|---|--:|--:|--:|---|
| 1 | `GLD` | SPDR Gold Trust | $5,824,718 | $12,509,474 | — | `0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e` |
| 2 | `AMC` | AMC Entertainment | $2,817,303 | $24,538,640 | — | `0x05a3d1Cd21d0C88145E82600E62e7E496e0F222B` |
| 3 | `HIMS` | Hims & Hers Health | $2,701,837 | $12,213,596 | — | `0xCceE82fE024c36fA15E1005edE3E9e4787e23D09` |
| 4 | `RDDT` | Reddit | $2,104,987 | $4,034,922 | — | `0x05b37Fb53A299a1b874A619e1c4C404D52C36F4C` |
| 5 | `LLY` | Eli Lilly | $1,725,561 | $2,553,004 | — | `0x8005d266423c7ea827372c9c864491e5786600ea` |
| 6 | `TTWO` | Take-Two Interactive Software | $1,600,653 | $2,710,778 | — | `0x5e81213613b6B86EaB4c6c50d718d34359459786` |
| 7 | `RBLX` | Roblox | $1,564,596 | $7,907,097 | — | `0xF0C4BF4C582cb3836e98394b1d4e7B7281101bE8` |
| 8 | `COST` | Costco | $1,482,212 | $2,172,377 | — | `0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2` |
| 9 | `DJT` | Trump Media & Technology Group | $1,289,572 | $3,729,788 | — | `0x1D11f0496982706C5e14A514D4E79F2e6BdE4516` |
| 10 | `SNAP` | Snap | $849,061 | $37,517,358 | — | `0xF6589F11Bc40b669e584073F428B05562F568733` |
| 11 | `JNJ` | Johnson & Johnson | $694,490 | $5,684,484 | — | `0x03DfbBE0AC4E7bCDaFd08eD41A400326B77D8c80` |
| 12 | `LULU` | Lululemon | $638,747 | $16,937,176 | — | `0x4e62068525Ab11FE768e29dfD00ef909B9803016` |
| 13 | `MRVL` | Marvell Technology | $443,538 | $18,768,762 | — | `0x62fd0668e10D8B72339BE2DCF7643001688ff13B` |
| 14 | `MRNA` | Moderna | $416,361 | $13,290,347 | — | `0x43B07D15cE533bEc5476d70C22a78a1B2B662155` |
| 15 | `QUBT` | Quantum Computing | $360,759 | $4,699,334 | — | `0x59818904ab4cE163b3cE4FfB64f2D6Ca02c434B4` |
| 16 | `INDA` | iShares MSCI India ETF | $350,195 | $2,902,125 | — | `0xACEF2e09adb47aD6aBeBAD9fF06689E60615C2B6` |
| 17 | `PFE` | Pfizer | $324,396 | $26,723,755 | — | `0x7066A64c24e4206CD62E83bf198c1E7EB361F51e` |
| 18 | `FIG` | Figma | $290,838 | $16,821,465 | — | `0x41F4267525a8AFf329540eF24fD83d9044758B33` |
| 19 | `BE` | Bloom Energy | $278,832 | $15,640,393 | — | `0x822CC93fFD030293E9842c30BBD678F530701867` |
| 20 | `RIVN` | Rivian Automotive | $256,291 | $14,345,954 | — | `0xB1BF26c1D20ff267A4f93550d1E0d06ac40a114B` |
| 21 | `NFLX` | Netflix | $249,969 | $24,006,349 | — | `0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8` |
| 22 | `WYFI` | WhiteFiber, Inc. | $247,858 | $2,484,875 | — | `0x9e7ABD3C9139D14E4c86DcE0e455AAB7A0C2FB3E` |
| 23 | `BB` | Blackberry | $233,952 | $8,279,785 | — | `0x48E39E56aCdbA37b09020C0b734A613C9a2f100A` |
| 24 | `IBM` | IBM | $215,904 | $4,375,399 | — | `0x980dcf6766FA79f5Cf0c4AAdb3ab477ff15a9619` |
| 25 | `UPS` | UPS | $210,553 | $4,812,816 | — | `0xf23250dac154D05Bb671CB0d0eBEf3c635c79CE2` |

...dan 134 lainnya. Kelompok tanpa-feed memikul $1,623,592,432 volume RFQ 24 jam
(62% dari total).

## Seluruh 194 token, urut kedalaman

| # | Simbol | Nama | Kedalaman | Vol 24j | Feed | Alamat |
|--:|---|---|--:|--:|--:|---|
| 1 | `NVDA` | NVIDIA | $12,332,411 | $134,681,610 | ✅ | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| 2 | `SPY` | SPDR S&P 500 ETF Trust | $7,227,703 | $43,531,466 | ✅ | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` |
| 3 | `GLD` | SPDR Gold Trust | $5,824,718 | $12,509,474 | — | `0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e` |
| 4 | `SPCX` | Space Exploration Technologies C | $4,533,323 | $121,333,531 | ✅ | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` |
| 5 | `MU` | Micron Technology | $3,368,614 | $24,175,723 | ✅ | `0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD` |
| 6 | `QQQ` | Invesco QQQ | $3,095,612 | $29,449,629 | ✅ | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` |
| 7 | `AMC` | AMC Entertainment | $2,817,303 | $24,538,640 | — | `0x05a3d1Cd21d0C88145E82600E62e7E496e0F222B` |
| 8 | `HIMS` | Hims & Hers Health | $2,701,837 | $12,213,596 | — | `0xCceE82fE024c36fA15E1005edE3E9e4787e23D09` |
| 9 | `AAPL` | Apple | $2,107,345 | $37,225,806 | ✅ | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` |
| 10 | `RDDT` | Reddit | $2,104,987 | $4,034,922 | — | `0x05b37Fb53A299a1b874A619e1c4C404D52C36F4C` |
| 11 | `GME` | GameStop | $1,945,718 | $7,226,765 | ✅ | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` |
| 12 | `LLY` | Eli Lilly | $1,725,561 | $2,553,004 | — | `0x8005d266423c7ea827372c9c864491e5786600ea` |
| 13 | `TSLA` | Tesla | $1,660,646 | $63,600,988 | ✅ | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` |
| 14 | `TTWO` | Take-Two Interactive Software | $1,600,653 | $2,710,778 | — | `0x5e81213613b6B86EaB4c6c50d718d34359459786` |
| 15 | `RBLX` | Roblox | $1,564,596 | $7,907,097 | — | `0xF0C4BF4C582cb3836e98394b1d4e7B7281101bE8` |
| 16 | `GOOGL` | Alphabet Class A | $1,515,880 | $20,726,615 | ✅ | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` |
| 17 | `COST` | Costco | $1,482,212 | $2,172,377 | — | `0x4EA005168D7F09a7A0Ba9D1DEf21a479950E44C2` |
| 18 | `CRCL` | Circle Internet Group | $1,373,899 | $24,733,421 | ✅ | `0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5` |
| 19 | `DJT` | Trump Media & Technology Group | $1,289,572 | $3,729,788 | — | `0x1D11f0496982706C5e14A514D4E79F2e6BdE4516` |
| 20 | `TSM` | Taiwan Semiconductor Manufacturi | $1,257,982 | $7,827,652 | ✅ | `0x58FfE4a942d3885bAa22D7520691F611EF09e7AA` |
| 21 | `AMZN` | Amazon | $1,028,609 | $26,891,496 | ✅ | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` |
| 22 | `MSFT` | Microsoft | $1,027,615 | $24,125,540 | ✅ | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` |
| 23 | `MSTR` | Strategy Inc. | $1,023,758 | $45,245,416 | ✅ | `0xec262a75e413fAfD0dF80480274532C79D42da09` |
| 24 | `SGOV` | iShares 0-3 Month Treasury Bond | $872,946 | $21,303,339 | ✅ | `0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5` |
| 25 | `SNAP` | Snap | $849,061 | $37,517,358 | — | `0xF6589F11Bc40b669e584073F428B05562F568733` |
| 26 | `USO` | United States Oil Fund | $808,005 | $4,036,628 | ✅ | `0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344` |
| 27 | `PLTR` | Palantir Technologies | $771,413 | $38,107,977 | ✅ | `0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A` |
| 28 | `JNJ` | Johnson & Johnson | $694,490 | $5,684,484 | — | `0x03DfbBE0AC4E7bCDaFd08eD41A400326B77D8c80` |
| 29 | `LULU` | Lululemon | $638,747 | $16,937,176 | — | `0x4e62068525Ab11FE768e29dfD00ef909B9803016` |
| 30 | `DELL` | Dell | $629,926 | $20,327,940 | ✅ | `0x941AE714EC6D8130c7B75d67160Ca08f1e7d11Dd` |
| 31 | `META` | Meta Platforms | $621,390 | $19,737,139 | ✅ | `0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35` |
| 32 | `AMD` | AMD | $545,953 | $14,867,890 | ✅ | `0x86923f96303D656E4aa86D9d42D1e57ad2023fdC` |
| 33 | `SNDK` | Sandisk Corporation | $499,319 | $8,688,931 | ✅ | `0xB90A19fF0Af67f7779afF50A882A9CfF42446400` |
| 34 | `MRVL` | Marvell Technology | $443,538 | $18,768,762 | — | `0x62fd0668e10D8B72339BE2DCF7643001688ff13B` |
| 35 | `MRNA` | Moderna | $416,361 | $13,290,347 | — | `0x43B07D15cE533bEc5476d70C22a78a1B2B662155` |
| 36 | `BABA` | Alibaba | $403,901 | $8,602,290 | ✅ | `0xad25Ac6C84D497db898fa1E8387bf6Af3532a1c4` |
| 37 | `INTC` | Intel | $383,615 | $79,927,772 | ✅ | `0xc72b96e0E48ecd4DC75E1e45396e26300BC39681` |
| 38 | `SLV` | iShares Silver Trust | $381,247 | $13,837,399 | ✅ | `0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f` |
| 39 | `COIN` | Coinbase | $379,075 | $13,741,513 | ✅ | `0x6330D8C3178a418788dF01a47479c0ce7CCF450b` |
| 40 | `QUBT` | Quantum Computing | $360,759 | $4,699,334 | — | `0x59818904ab4cE163b3cE4FfB64f2D6Ca02c434B4` |
| 41 | `INDA` | iShares MSCI India ETF | $350,195 | $2,902,125 | — | `0xACEF2e09adb47aD6aBeBAD9fF06689E60615C2B6` |
| 42 | `PFE` | Pfizer | $324,396 | $26,723,755 | — | `0x7066A64c24e4206CD62E83bf198c1E7EB361F51e` |
| 43 | `FIG` | Figma | $290,838 | $16,821,465 | — | `0x41F4267525a8AFf329540eF24fD83d9044758B33` |
| 44 | `BE` | Bloom Energy | $278,832 | $15,640,393 | — | `0x822CC93fFD030293E9842c30BBD678F530701867` |
| 45 | `RIVN` | Rivian Automotive | $256,291 | $14,345,954 | — | `0xB1BF26c1D20ff267A4f93550d1E0d06ac40a114B` |
| 46 | `NFLX` | Netflix | $249,969 | $24,006,349 | — | `0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8` |
| 47 | `WYFI` | WhiteFiber, Inc. | $247,858 | $2,484,875 | — | `0x9e7ABD3C9139D14E4c86DcE0e455AAB7A0C2FB3E` |
| 48 | `BB` | Blackberry | $233,952 | $8,279,785 | — | `0x48E39E56aCdbA37b09020C0b734A613C9a2f100A` |
| 49 | `IBM` | IBM | $215,904 | $4,375,399 | — | `0x980dcf6766FA79f5Cf0c4AAdb3ab477ff15a9619` |
| 50 | `UPS` | UPS | $210,553 | $4,812,816 | — | `0xf23250dac154D05Bb671CB0d0eBEf3c635c79CE2` |
| 51 | `USAR` | USA Rare Earth | $207,749 | $7,547,309 | ✅ | `0xd917B029C761D264c6A312BBbcDA868658eF86a6` |
| 52 | `NU` | Nu | $201,801 | $81,820,282 | — | `0x408c14038a04f7bD235329E26d2bf569ee20e250` |
| 53 | `ASML` | ASML Holding NV | $192,266 | $1,439,231 | ✅ | `0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA` |
| 54 | `BA` | Boeing | $187,057 | $6,262,050 | — | `0x4D21483a44Bf67a86b77E3dA301411880797D452` |
| 55 | `PENG` | Penguin Solutions | $176,180 | $1,112,431 | — | `0x9b23573b156B52565012F5cE02CDF60AFBaa70Be` |
| 56 | `BULL` | Webull | $164,615 | $32,701,626 | — | `0xceF9027c7d6985b85f0BA431125073529A947A68` |
| 57 | `SOXX` | iShares Semiconductor ETF | $158,859 | $6,445,358 | — | `0x75742c18BC1f1C5c5f448f4C9D9C6F66dafAAa38` |
| 58 | `RCAT` | Red Cat | $151,964 | $6,472,591 | — | `0xFDE6b5d9BB419B10C23268c74e369AbFF39C0460` |
| 59 | `SHOP` | Shopify | $136,616 | $5,952,869 | — | `0xF53F66751B1Eff985311b693531E3290F600c410` |
| 60 | `ADBE` | Adobe | $126,247 | $3,548,180 | — | `0x232B8ed6377BE97813853B0Ac104c4Cda8378d1B` |
| 61 | `SKHY` | SK hynix Inc. American Depositar | $125,863 | $14,757,657 | — | `0x84CAb63bc87912E71ad199ff14A0bA45de68FeF8` |
| 62 | `ON` | ON Semiconductor | $124,926 | $8,140,589 | — | `0xbBD09F72b025360FeE5C928053Dca6248d35be54` |
| 63 | `DDOG` | Datadog | $123,332 | $4,838,671 | — | `0x27c99fBde9D0d2AA4f4Bfb4943f237843DdF6958` |
| 64 | `ZM` | Zoom | $118,432 | $2,401,512 | — | `0x44c4F142009036cF477eD2d09932051843137CF1` |
| 65 | `RUN` | Sunrun | $105,497 | $7,322,367 | — | `0x756Bc80af765C82da966a788858d65aDF14f3793` |
| 66 | `F` | Ford Motor | $104,642 | $40,628,415 | — | `0x25C288E6D899b9BC30160965aD9644c67e73bE0C` |
| 67 | `SNOW` | Snowflake | $103,353 | $21,835,774 | — | `0xBa0CAB75495255d0cB58E22B648bFED4ECD1F47E` |
| 68 | `NET` | Cloudflare, Inc. Class A common  | $98,378 | $2,972,897 | — | `0x116F00968269B7bfbaD4109cE591d6E74c0601d4` |
| 69 | `HPE` | HP Enterprise | $97,448 | $72,139,283 | — | `0x59dd09d4900C2E4B5F75b7c0d4E6796fcc234Cb1` |
| 70 | `CEG` | Constellation Energy | $96,313 | $3,138,973 | — | `0xaE517A2903E68bd929Dfd15be875F8369D53e94a` |
| 71 | `GE` | General Electric | $95,210 | $2,653,397 | — | `0x63b814DDBd6BF339f25Fed8c36158a008D5B373e` |
| 72 | `CVNA` | Carvana | $92,241 | $5,867,296 | — | `0xa4f319104089FE321dc8093C6E707d4fE190A988` |
| 73 | `SOUN` | SoundHound AI | $90,040 | $23,514,127 | — | `0x6E3Dfd9f7e1649BaA14D25cac18C94d62dB10A54` |
| 74 | `CCL` | Carnival Corporation | $87,551 | $19,918,892 | — | `0x9651342CeA770aE9a2969Ba2A52611523146aef9` |
| 75 | `LMT` | Lockheed | $86,699 | $772,703 | — | `0x329fcACEb9AD6F9580DD5F643fed0646900D043c` |
| 76 | `XOM` | ExxonMobil Holdings Corporation | $85,702 | $13,760,871 | — | `0xf9B46d3D1B22199D4D1025a9cEDB540A33F1a2d5` |
| 77 | `WDAY` | Workday | $84,921 | $2,982,838 | — | `0x82DA4646242e1D962e96e932269Dc644c94a9CaA` |
| 78 | `RKLB` | Rocket Lab Corporation | $84,251 | $18,913,089 | ✅ | `0x3b14C39E89D60D627b42a1A4CA45b5bb45Fc12e2` |
| 79 | `P` | Everpure | $84,111 | $2,668,330 | — | `0x1Cdad396DB64BDa184d5182A97Dd9B3C62100b7D` |
| 80 | `ASTS` | AST SpaceMobile | $73,062 | $7,743,564 | — | `0x1AF6446f07eb1d97c546AFC8c9544cBDF3AD5137` |
| 81 | `UNH` | UnitedHealth | $64,144 | $5,489,533 | — | `0xcF364ea52787e289De6F32077834056E3E70D6A8` |
| 82 | `SOFI` | SoFi Technologies | $62,593 | $43,721,421 | — | `0x98E75885157C80992A8D41b696D8c9C6Fb30A926` |
| 83 | `FIX` | Comfort Systems | $62,574 | $265,874 | — | `0x93Dbb1d2Dc5D63F4abACFF30485273f538Df68Ac` |
| 84 | `GLXY` | Galaxy Digital Inc. | $59,249 | $8,513,260 | — | `0x2D427692E928fa156ec22acfaBaFA0447C5805B7` |
| 85 | `FLY` | Firefly Aerospace Inc. | $57,064 | $1,817,690 | — | `0x03BC731Ffb162cdd7B98D3C6542bFC291126075d` |
| 86 | `CSCO` | Cisco Systems | $46,954 | $14,217,325 | — | `0xF543967EEBB6f1917992eF0E68De63ab07a5a0dA` |
| 87 | `SPMO` | Invesco S&P 500 Momentum ETF | $44,582 | $1,302,408 | — | `0xAd622320e520de39e72d41EF07438C3Fd3354875` |
| 88 | `CRM` | Salesforce | $43,753 | $16,037,820 | — | `0xd95B44124e475743a7589e68F3D74008A5536D44` |
| 89 | `XLK` | State Street Technology Select S | $43,100 | $6,094,566 | — | `0x15Cd20759CE7F3285c29A319dE2D1A2e098c6f43` |
| 90 | `ORCL` | Oracle | $43,048 | $25,101,700 | ✅ | `0xb0992820E760d836549ba69BC7598b4af75dEE03` |
| 91 | `WULF` | TeraWulf | $42,766 | $37,184,190 | — | `0x348Be1A8663f15edDe5CDf8A96BB69078f7aB6Fd` |
| 92 | `CRWV` | CoreWeave | $41,604 | $18,798,407 | ✅ | `0x5f10A1C971B69e47e059e1dC91901B59b3fB49C3` |
| 93 | `SCHD` | Schwab US Dividend Equity ETF | $41,156 | $21,395,133 | — | `0xd63ABB2C13d7a8421a8017a712802053568e3C1D` |
| 94 | `LITE` | Lumentum | $41,004 | $3,304,999 | — | `0x8eF20885F94e3D9bc7eB3080279188Bd5ED7c08C` |
| 95 | `KSS` | Kohls Corporation | $40,548 | $3,347,723 | — | `0x12e3c047bf9AeCAF9dDC98c05C31BFD1dd043993` |
| 96 | `NNE` | Nano Nuclear Energy | $40,103 | $1,281,019 | — | `0xBEF75684C43c4ea7BD18Dd532a2244674Ee8b926` |
| 97 | `HII` | Huntington Ingalls | $39,837 | $287,934 | — | `0xEB61c0Ed490A367d4E3631cCf8a74B3bfc7E775D` |
| 98 | `TER` | Teradyne | $39,354 | $1,692,251 | — | `0x2778C5024D5cA2CdB0f8eAD671ffc69963AdCD9C` |
| 99 | `AAOI` | Applied Optoelectronics | $38,636 | $5,917,886 | — | `0x521Cf887E6531c6F667b5BC4D896E5d9bfE8EB2E` |
| 100 | `FUTU` | Futu Holdings | $38,529 | $1,001,289 | — | `0xeB30663bDFf0622Ef4e4E5cBb4E975F19f33f51D` |
| 101 | `MDB` | MongoDB | $38,508 | $2,666,233 | — | `0xDdf2266b79abf0B48898959B0ed6E6adf512be74` |
| 102 | `PL` | Planet Labs | $38,327 | $31,952,725 | — | `0xAA4d64474c172010aB57719cb9951E6142a100d3` |
| 103 | `TTD` | Trade Desk | $38,297 | $23,639,906 | — | `0x0b5fb4031cae9163db10B169Ee72685F0EdC8545` |
| 104 | `SIMO` | Silicon Motion | $37,916 | $885,740 | — | `0x77E655E37F4d913fB9540e0d541D824171a60e81` |
| 105 | `TE` | T1 Energy | $37,326 | $16,409,216 | — | `0xb1969f6604CA1AE7a2cD3F1827876e914594CA2D` |
| 106 | `APLD` | Applied Digital | $37,230 | $15,965,483 | — | `0xb8DBf92F9741c9ac1c32115E78581f23509916FD` |
| 107 | `AVGO` | Broadcom | $37,032 | $60,242,586 | — | `0x156E175DD063a8cE274C50654eF40e0032b3fbcF` |
| 108 | `NOW` | ServiceNow | $36,416 | $18,172,324 | — | `0x0C3260aF4B8f13a69c4c2dFb84fD667890CDFa14` |
| 109 | `LUNR` | Intuitive Machines | $33,956 | $6,839,164 | — | `0xa5D4968421bA94814Be3B136b15cf422101aC1a3` |
| 110 | `POET` | POET Technologies | $32,793 | $6,172,657 | — | `0xcf6B2D875361be807EAfa57458c80f28521F9333` |
| 111 | `HWM` | Howmet Aerospace | $32,781 | $3,232,933 | — | `0xAEa445c5F3DB1a462998ccC422A875A361ee5d99` |
| 112 | `JOBY` | Joby Aviation | $32,641 | $29,587,990 | — | `0xb334C5cE741B80B5B671F47F5C269Cb193fe8E24` |
| 113 | `AUR` | Aurora Innovation | $32,489 | $55,341,173 | — | `0x373C06c4f7BDe527D7Dae4BA169E42b55E393CeD` |
| 114 | `IBRX` | ImmunityBio, | $32,395 | $5,271,713 | — | `0x7c148F74ac7445D1F28366b7FcDC6792a9Fcd0Cf` |
| 115 | `FTNT` | Fortinet | $31,981 | $3,124,334 | — | `0x3FB8976980d486084b2eb4a404BD12e72823958f` |
| 116 | `INTU` | Intuit | $30,625 | $3,695,914 | — | `0x56d23beE5f41A7120170b0c603Dae30128e460e9` |
| 117 | `VRT` | Vertiv | $30,370 | $4,245,644 | — | `0xFA78C12E6488814A0262E4e802749a4a737d5fB7` |
| 118 | `APP` | AppLovin | $30,342 | $4,462,875 | — | `0xA249BAF1063Af884807C1E1400AEf7784836917E` |
| 119 | `ELF` | e.l.f. Beauty | $30,123 | $1,683,665 | — | `0x39EC44Bee4F6A116c6F9B8De566848a985C53C60` |
| 120 | `EWY` | iShares MSCI South Korea fund | $30,078 | $10,934,363 | ✅ | `0x7f0aBeF0C07280F82c6a08ead09dEd6BAE2C13Fc` |
| 121 | `FICO` | Fair Isaac | $29,408 | $203,130 | — | `0xa48F22A46C0F1C46CA7D111CB6c137c271987180` |
| 122 | `ALAB` | Astera Labs, Inc. | $28,788 | $2,790,319 | — | `0x748c32c3ca24eDf31ea597Db1F3d330a7a6DA3Dc` |
| 123 | `CELH` | Celsius | $28,554 | $4,932,058 | — | `0x8cF07C5A878945185d327aAa6e33FAa95F95e7bF` |
| 124 | `TEAM` | Atlassian Corporation | $28,370 | $3,355,194 | — | `0x5B97476b922F3305131B8f0B9D333172E87f4aaE` |
| 125 | `QCOM` | Qualcomm | $28,213 | $6,994,690 | — | `0x0f17206447090e464C277571124dD2688E48AEA9` |
| 126 | `TSEM` | Tower Semiconductor | $28,147 | $1,102,580 | — | `0x89776d4Cd68193597A2fC132cfaC1fDe36CCeA8a` |
| 127 | `IREN` | IREN Limited | $27,885 | $44,985,212 | — | `0xF0AB0c93bE6F41369d302e55db1A96b3c430212D` |
| 128 | `SMR` | NuScale Power | $27,614 | $28,750,539 | — | `0x1Eebee7F74517e0279dFb09d25B0407bEEc3FDd6` |
| 129 | `PANW` | Palo Alto Networks | $26,601 | $6,912,607 | — | `0xB039597eD45CBa7B6E2fb9E8BE51802969CEe5Be` |
| 130 | `RGTI` | Rigetti Computing | $26,542 | $14,140,597 | ✅ | `0x284358abc07F9359f19f4b5b4aC91901Be2597Ba` |
| 131 | `PATH` | UiPath | $26,491 | $62,678,731 | — | `0xfb2664f07B6Aadd29ea7a59D8859b1AeB8645cDa` |
| 132 | `EWT` | iShares MSCI Taiwan Capped ETF | $26,178 | $3,557,185 | — | `0x1c690498150252222C275A5CEd69d3A6b1f52D5E` |
| 133 | `PWR` | Quanta | $25,367 | $862,413 | — | `0x9Ab02Ead789b6903c3c44d0ED32F9c707CDF12FD` |
| 134 | `CLOV` | Clover Health Investments | $25,287 | $2,945,409 | — | `0x62200915e7DEab1eC7f79fb246daDbB80eACdDd0` |
| 135 | `QBTS` | D-Wave Quantum Inc. Common Stock | $25,161 | $11,015,874 | — | `0xC583c60aeF9Dc401Da72cEC1B404743a93cea1Cc` |
| 136 | `FLNC` | Fluence Energy | $25,139 | $8,677,649 | — | `0x282e87451E10fA6679BC7D76C69BE44cD3fC777C` |
| 137 | `AEIS` | Advanced Energy | $24,025 | $571,300 | — | `0xfAf9cb261B5FCC1f404Bb10CD39C5c6C1974E612` |
| 138 | `WDC` | Western Digital | $23,796 | $5,519,051 | — | `0xF52597345A8Edf418bc4071b4a35112472277D3e` |
| 139 | `AMBA` | Ambarella | $23,784 | $2,730,970 | — | `0x99D9D8663545151603863C5AcbD6FC3218899009` |
| 140 | `CLSK` | CleanSpark | $23,548 | $23,533,915 | ✅ | `0xcBB95BBF36099d34dA091dc6Fa6F49EfA257Cee3` |
| 141 | `FISV` | Fiserv | $23,452 | $4,729,218 | — | `0x9ECe29A4A2397C0a35fb5fA8EE2b9509130a98cc` |
| 142 | `KTOS` | Kratos Defense & Security Soluti | $23,185 | $3,889,540 | — | `0x7FD06a4d81cCfA3F351394E144d5191874C31313` |
| 143 | `IONQ` | IonQ | $23,025 | $14,009,182 | ✅ | `0x558378E000D634A36593E338eBacdd6207640EfE` |
| 144 | `NBIS` | Nebius Group | $22,143 | $10,679,503 | ✅ | `0x9D9c6684F596F66a64C030B93A886D51Fd4D7931` |
| 145 | `INOD` | Innodata | $22,129 | $600,791 | — | `0xf1953DAB6FaD537488d5A022361FfAa8B4c95eC6` |
| 146 | `MXL` | MaxLinear | $22,080 | $2,391,405 | — | `0x48961813349333209994750ffA89b3c5C22eC969` |
| 147 | `LRCX` | Lam Research Corp | $21,669 | $7,211,392 | — | `0x57b0030166DB0C31690d1A5aA167e2e26e2C29a4` |
| 148 | `VST` | Vistra | $21,348 | $4,330,982 | — | `0x561e2a49212b7cCF47f2744Ccb83e200722fADBc` |
| 149 | `SMCI` | Super Micro Computer | $21,201 | $34,435,774 | — | `0xc01aA1fECeC0605b13bc84874ff7256C0f5F562a` |
| 150 | `CLS` | Celestica | $20,686 | $3,897,462 | — | `0xBf449977089c718C004a66C554B26B94ef3Ad4De` |
| 151 | `DOCN` | DigitalOcean | $20,658 | $1,846,864 | — | `0xc02f12B9fe9E707079EC0d546f3050d3F6C1F8bD` |
| 152 | `CBRS` | Cerebras Systems | $20,553 | $4,968,723 | — | `0x5c90450Bbb4273D7b2f17CF6917AEB237A569679` |
| 153 | `SHY` | iShares 1-3 Year Treasury Bond E | $20,418 | $3,601,269 | — | `0xBE274710Bf3d9567e1B290eF6a5F9f90ca016FD8` |
| 154 | `SMH` | VanEck Semiconductor ETF | $20,326 | $5,623,201 | — | `0x072f979c2CAc8e1391B0162a87Fee094bF8744a0` |
| 155 | `VSAT` | ViaSat | $20,242 | $1,759,751 | — | `0x26dCbfb34FC83CAbD6990f449674efDc6097fF85` |
| 156 | `UMC` | United Microelectronics | $20,136 | $6,068,145 | — | `0x0E6e67Ba88e7b5d9B67636A215c76779B948dE79` |
| 157 | `SLS` | SELLAS Life Sciences | $19,644 | $5,783,361 | — | `0x285b231728c7E4333799183DF1094d775246a535` |
| 158 | `OKLO` | Oklo | $19,583 | $6,970,318 | — | `0x8B2f88497f15A18E9D4FFa1a8fFB8538399aE774` |
| 159 | `ZS` | Zscaler | $19,538 | $8,514,140 | — | `0x7dc013eB55e436f30d7ED1AFE4E36d6e45e3c3f7` |
| 160 | `ABCL` | Abcellera Biologics | $19,476 | $3,289,792 | — | `0x3139D77Ace0cbAA5bDfD38bD1F1911a794AF0B0e` |
| 161 | `ANET` | Arista | $19,269 | $4,110,715 | — | `0x28bABD556b60E53663B8615036479a29c2CDd1Bf` |
| 162 | `MPWR` | Monolithic Power Systems | $18,853 | $413,615 | — | `0x52D50D0280AD1054b43f052bD70a49a212A1b128` |
| 163 | `CRDO` | Credo Technology Group | $18,432 | $13,770,220 | — | `0x4D67253bc223e6b0e104F1084c1fb2b669dDC41b` |
| 164 | `GLW` | Corning | $18,366 | $8,651,782 | — | `0x7c04E6A3368F2A1DE3874f0e80d2e0A1a9915da6` |
| 165 | `AVAV` | AeroVironment | $18,341 | $2,387,248 | — | `0xF6290b5e7C26502e2dA514C31509849718EA76A5` |
| 166 | `LHX` | L3Harris | $18,322 | $1,414,101 | — | `0x48d60243c66437c6ac3c2495Be94747aEd5Dfe25` |
| 167 | `KLAC` | KLA | $18,142 | $6,863,407 | — | `0x96b933C74eCB4A0926b9210cef7b743EF46be2E9` |
| 168 | `COHR` | Coherent | $17,945 | $4,218,651 | — | `0x92F9F459F1a9a5AD266b182BE7Bffd1C6c666894` |
| 169 | `ONTO` | Onto Innovation | $17,835 | $852,284 | — | `0x8ff63eAeEe3fE54Ba450c4F5538064Ec5A893Aef` |
| 170 | `TEM` | Tempus AI | $17,575 | $4,918,168 | — | `0xB1CC0EC7Db69Cf43539119814df40071b9d61793` |
| 171 | `PR` | Permian Resources | $17,518 | $5,837,716 | — | `0x4189F0c66EBBB0bfeF1C31f763131361EF32f77C` |
| 172 | `MOD` | Modine | $16,985 | $1,184,431 | — | `0xc6Cbad1016b38B797610c25E1dc7D95988B1f362` |
| 173 | `POWL` | Powell Industries | $16,893 | $617,986 | — | `0x237c16D66590F67B886d978ACD362EAeaD8B18c7` |
| 174 | `JBL` | Jabil Inc. | $16,441 | $1,134,468 | — | `0xEAf2512dFC1bEAc608F8794B3793CD4E02894Aa6` |
| 175 | `CIEN` | Ciena | $16,019 | $7,535,403 | — | `0x44f6D488021f8233B9416294d1FE9b1fEe28382d` |
| 176 | `XNDU` | Xanadu Quantum | $15,863 | $1,116,037 | — | `0xA8eB3BCcbf2017eE7CBfb652eB51CF2E1B153289` |
| 177 | `INFQ` | Infleqtion | $15,813 | $5,711,524 | — | `0xB853bC83a753342a4f8320ea680b4B1E84118D21` |
| 178 | `OUST` | Ouster | $15,656 | $1,895,738 | — | `0x40E7a279850e443f582059ae5dC1c3b6563E6395` |
| 179 | `AMAT` | Applied Materials | $15,428 | $6,004,375 | — | `0x36046893810a7E7fCE501229d57dc3FC8c8716d0` |
| 180 | `GEV` | GE Vernova | $15,240 | $1,764,308 | — | `0x94B8AAE43A1cCc08Aa64B7D1F29b4D920aF4a0C9` |
| 181 | `AMKR` | Amkor Technology | $15,130 | $3,885,462 | — | `0xDd356AA38F40A7b7076755aC854B6FBb1F0D305B` |
| 182 | `NVTS` | Navitas Semiconductor | $14,970 | $12,144,623 | — | `0xbE6702d7b70315376dC48a3293f24f0982F86386` |
| 183 | `AXON` | Axon | $14,846 | $859,142 | — | `0xC27dBD474aF5181c5A8777903690D8D262D12648` |
| 184 | `AXTI` | AXT | $13,994 | $7,225,417 | — | `0x141eEa040c2250eEc0314e336975e81f85f6585e` |
| 185 | `RDW` | Redwire | $13,961 | $11,882,642 | — | `0x92Ef19E82bD8fF36661DE838D5eaE7e5CEF0EfFE` |
| 186 | `CTSH` | Cognizant | $13,318 | $4,430,998 | — | `0x63D5a3b6939a33f1e75d8Bcd85759858239600DB` |
| 187 | `NAVN` | Navan | $12,724 | $1,949,550 | — | `0xf7181b63Fdb858558A74ba96BC42732684cd7965` |
| 188 | `VTI` | Vanguard Morningstar Total Stock | $11,654 | $2,565,937 | — | `0x0594134DF3f171a354D9C85eBD65b7A6148F6D09` |
| 189 | `MTSI` | MACOM | $11,632 | $896,048 | — | `0xC93f4d80e268AB922e871bd169156C3CC41894e6` |
| 190 | `VICR` | Vicor | $10,782 | $519,883 | — | `0x6006ed4B2F94110851ff7509D97D034f0EeD9226` |
| 191 | `AEHR` | Aehr | $10,424 | $4,541,313 | — | `0x5F604fBA1162193A4388A5DFa56F556f3E133cC2` |
| 192 | `CRWD` | CrowdStrike Holdings | $8,730 | $12,069,883 | — | `0xea72Ecca2d0f6bFA1394DBBCff85b52CD4233931` |
| 193 | `SATS` | EchoStar | $0 | $3,742,627 | — | `0x95052ddcd5DC25641657424A8Cf04834997E1730` |
| 194 | `BND` | Vanguard Total Bond Market ETF | $0 | $9,481,499 | — | `0x2F62fC9fAbb470C690f141c28340eD832bB27020` |
