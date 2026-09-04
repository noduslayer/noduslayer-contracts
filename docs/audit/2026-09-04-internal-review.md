# NodusLayer v1 — Internal Security Review

**Date** 2026-09-04 · **Commit** working tree before first commit · **Chain** Robinhood Chain (4663)
**Scope** `contracts/src/**` (StockRegistry, BasketFactory, BasketToken, BasketZap, BasketLens, interfaces)
**Superseded in part** — since this review the registry accepts feed-less listings, the zap batches its
approvals and keeps a standing basket allowance, and weight caps were recalibrated to retail ticket sizes.
Those changes are covered by tests but have not been re-reviewed end to end; do that before an audit.
**Out of scope** deploy scripts (reviewed for correctness only), off-chain quote service, front end, legal.

This is an internal review by the implementing engineer, not an independent audit. It is meant to
hand an external auditor a clean starting point: every tool finding is either fixed or explained,
and every accepted risk is written down.

## Method

1. Manual read of every contract against a fixed checklist: access control, accounting and
   rounding direction, reentrancy / checks-effects-interactions, oracle handling, external-call
   surface, denial of service, token quirks (fee-on-transfer, rebasing, pausable, block-lists),
   upgradeability of dependencies.
2. Static analysis: Slither 0.11.5 (101 detectors), Aderyn 0.6.8, `forge lint`.
3. Tests: 124 unit tests including fuzzing of the backing invariant (512 runs), effectively full coverage
   of `src/`, and 10 fork tests across four files against mainnet 4663 — covering in-kind mint and redeem
   with real tokens, zap routing through the real Uniswap v3 SwapRouter02, retail gas cost, listing the
   full 194-token universe, and deploying the entire 60-basket catalogue against live Chainlink prices.
4. On-chain reconnaissance of the dependencies the design relies on (token proxy layout, issuer
   powers, feed parameters, router deployments).

Toolchain: Foundry 1.5.1, solc 0.8.30 (cancun, optimizer 10k runs), OpenZeppelin 5.7.0.

## Findings

| ID | Severity | Status | Title |
|---|---|---|---|
| L-01 | Low | Fixed | `StockRegistry.setFeed` rejected delisted tokens, freezing prices for live baskets |
| L-02 | Low | Fixed | `BasketLens.nav(basket, maxAge)` reverted with an arithmetic panic for large `maxAge` |
| I-01 | Info | Fixed | `BasketToken._redeem` interleaved ledger writes with token transfers |
| I-02 | Info | Fixed | Address parameters in `TreasuryUpdated` / `FeesUpdated` were not indexed |
| I-03 | Info | Fixed | Interface parameter names shadowed getters |
| I-04 | Info | Fixed | Unchecked `int256 → uint256` cast in `BasketLens.price` |
| I-05 | Info | Fixed | Lint: inline modifier logic, bit-test spelling |
| A-01 | — | Acknowledged | Aderyn H-1 "state change after external call" in `BasketFactory.createBasket` |
| A-02 | — | Acknowledged | Slither `unused-return` (6) |
| A-03 | — | Acknowledged | Slither `calls-loop` (18) |
| A-04 | — | Acknowledged | Slither `timestamp` (2) |
| A-05 | — | Acknowledged | Aderyn low/informational items (centralization, loops, literals, style) |

### L-01 — `setFeed` unusable after delisting (fixed)

`setFeed` required the token to be currently listed. Baskets are immutable, so a basket holding a
token that was later delisted still needs pricing, and Chainlink occasionally migrates feed
proxies. The old code would have left every such basket with a dead feed forever and no way to
repair it. The gate is now "token has ever been listed" (`feedOf[token] != 0`).
Test: `StockRegistryTest.test_SetFeed_StillWorksAfterDelist`.

### L-02 — Arithmetic panic in `nav(basket, maxAge)` (fixed)

`block.timestamp - maxAge` underflowed for `maxAge > block.timestamp`, surfacing as a panic
instead of a clean result. The cutoff now saturates at zero.
Test: `BasketLensTest.test_NavWithMaxAge_SaturatesHugeMaxAge`.

### I-01 — Redeem ordering (fixed)

`_redeem` recorded skipped-leg claims and transferred non-skipped legs in the same loop, so a
claim write could follow an external transfer. With `nonReentrant` on every entry point this was
not exploitable, but it violated checks-effects-interactions and was flagged by Aderyn. The
function now performs all ledger writes and emits `Redeemed` first, then transfers. Behaviour is
unchanged; the fuzzed backing invariant still holds.

### A-01 — Register-after-deploy in the factory (acknowledged)

The "external call" is `new BasketToken(...)`: creation of bytecode the factory itself compiles
in. No untrusted code executes between deployment and `isBasket[basket] = true`, and the
function is `onlyOwner`. Precomputing the address with CREATE2 to invert the order would add
complexity for no security gain.

### A-02 – A-04 — Slither informational detectors (acknowledged)

- `unused-return`: partial destructuring of `previewMint` and `latestRoundData` tuples;
  `Address.functionCall` return data is intentionally ignored (reverts bubble up); `decimals()`
  inside `try/catch` is a liveness probe; `redeem`'s return is unused in the zap because balances
  are re-read from the tokens themselves.
- `calls-loop`: loops are bounded by `MAX_CONSTITUENTS = 16` or by the caller's own `swaps`
  array, whose gas the caller pays.
- `timestamp`: deadline and feed-staleness comparisons are the intended use of `block.timestamp`.

## Invariants

For every constituent `i` of every basket, at all times:

```
balance_i · 1e18  ≥  totalSupply · units_i  +  totalClaimable_i · 1e18
```

Mint rounds constituent amounts up, redeem rounds down, fees are settled in shares (which are
themselves backed), and skipped legs move from "backing" to "owed" without leaving the vault.
Fuzzed in `BasketTokenTest.testFuzz_BackingCoversSupplyAndClaims`.

Other properties verified by tests: the zap ends every transaction with zero balance and zero
router allowances; redeem has no pause path; only `factory.owner()` can change fees, and only
within the 1 % cap; only allow-listed routers can be called; unknown baskets are rejected.

## Threat model

### Issuer of the stock tokens

Every Robinhood stock token is a `BeaconProxy` behind beacon `0xe10b…1b00` with shared
implementation `0xb354…5aE2`. The implementation exposes `pause/unpause`, `isBlocked`
(block-list), `mint(address,uint256)` and `burn(address,uint256)`; the beacon owner can replace
the logic for every token at once.

| Issuer action | Effect on a basket | Mitigation |
|---|---|---|
| pause a constituent | `redeem` reverts | `redeemWithSkip` exits the other legs; `claim` later |
| block-list the vault | `redeem` reverts for that leg, `mint` fails | same as above; basket closes to new supply |
| `burn` from the vault | under-collateralisation | none possible on-chain; monitor, curate, disclose |
| logic upgrade | arbitrary | monitor beacon `Upgraded`; registry can delist for new baskets |

### Protocol governance

The owner (to be a multisig behind a timelock) can: list/delist tokens and set feeds; create
baskets; change fees within caps (1 % mint/redeem, 0.5 % zap); change the treasury; allow-list
routers; pause the zap. It cannot pause redemption, move vault funds, or alter a recipe.
Ownership transfers are two-step.

The router allow-list is the sharpest lever: a malicious router combined with matching calldata
from a compromised front end could take a caller's in-flight funds inside that one transaction.
The zap never custodies funds between transactions, so the blast radius is bounded to that
transaction; keep the lever behind a timelock and allow-list only audited public routers.

### Market data

Chainlink stock feeds on this chain are `us_equities_24/5` with a 24 h heartbeat and 0.5 %
deviation threshold; they do not update on weekends while the AMMs trade 24/7. `BasketLens.nav`
therefore never reverts on age and returns the oldest feed timestamp for the caller to judge.
Slippage bounds for the zap must come from live quotes; the feed is a sanity bound only.

### Token assumptions

Constituents must be plain ERC-20s without transfer fees or rebasing. Robinhood stock tokens
satisfy this (ERC-8056 scales a UI multiplier instead of rebasing). The registry is the control
point; listing anything else would let `mint` under-collateralise.

## Evidence

- `forge test`: 124 passed, 0 failed (6 unit suites); fuzz 512 runs.
- `forge coverage`: 100 % lines, statements, branches and functions for every file in `src/`.
- Mainnet fork (`FORK_TESTS=true`, block ≈ 54.0 M, 2026-09-04):
  canonical token names verified; in-kind mint/redeem with real NVDA/AAPL;
  Chainlink NAV of the 0.20 NVDA + 0.15 AAPL test basket = 95.376 USD/share;
  `zapMint` of 0.05 shares through Uniswap v3 SwapRouter02 cost 4.806 USDG (≈ 0.8 % over NAV
  including 0.2 % zap fee, 0.1 % mint fee and two 0.05 % pools);
  `zapRedeem` of 0.5 shares returned 47.474 USDG (≈ 0.45 % under NAV); zap balances zero after each.
- Runtime sizes (bytes): BasketFactory 14,760 · BasketToken 9,440 · BasketZap 8,451 ·
  BasketLens 3,618 · StockRegistry 3,381 (limit 24,576).
- `forge lint`: 0 findings (excluded: `screaming-snake-case-immutable` by convention,
  `unsafe-cheatcode` for scripts/tests). `forge fmt --check`: clean.
- Slither / Aderyn raw output: `slither.json`, `aderyn.md` in this directory.

## Before mainnet

1. Independent audit of `src/` (small surface: ~600 lines).
2. Deploy owner = multisig behind a timelock; accept ownership; verify sources on Blockscout.
3. Monitoring: beacon upgrades and pause events on constituents, feed staleness, zap `Swept`.
4. Bug bounty.
5. Legal review of the index product in each target jurisdiction; geo-block US in the front end.

## Follow-ups (not blocking)

- `zapRedeem` variant that consumes an ERC-2612 permit for the basket shares.
- Native ETH input via WETH wrapping in the zap.
- Migration zap (v1 → v2 recipe) that trades only the recipe difference.
- Quote service: pool graph (Uniswap v2/v3/v4, Rialto), Quoter simulation, RFQ comparison,
  gas-aware objective, Chainlink sanity bound with market-hours-aware tolerance.
