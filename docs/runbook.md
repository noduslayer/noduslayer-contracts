# Operations runbook

Deployment, governance and incident response for NodusLayer on Robinhood Chain (chain id 4663, testnet
46630).

## Before mainnet

Blocking:

1. An independent audit of `contracts/src/`. The internal review in `docs/audit/` was written by the
   implementing engineer and is partly superseded by later changes; it is a starting point for an auditor,
   not a substitute for one.
2. Legal review of the index product in every jurisdiction served, and geo-blocking for US persons.
3. A rehearsal of this entire runbook on testnet 46630, including the timelock delay.

Recommended: a bug bounty, and monitoring live before the first basket is created.

## Deploying

The deployer key needs ETH for gas and nothing else. It never holds protocol funds and ends the process
with no authority.

```sh
cd contracts
export MULTISIG=0x...            # proposer, canceller and executor on the timelock
export TREASURY=0x...            # fee recipient
export TIMELOCK_MIN_DELAY=172800 # 2 days
export ZAP_FEE_BPS=20

forge script script/Deploy.s.sol --rpc-url robinhood --account deployer --broadcast \
  --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
```

This deploys the timelock, registry, factory, zap and lens, lists all 194 stock tokens in chunks,
allow-lists the routers from the config, and transfers ownership of the registry, factory and zap to the
timelock. Record every printed address in `docs/deployments.md` before continuing.

Ownership is staged, not final. `Ownable2Step` requires the incoming owner to accept, and the incoming owner
is the timelock, so acceptance is itself a governance action — the first one, and it takes the same path as
every later one. "Governance" below explains how the multisig submits what the scripts produce.

```sh
export TIMELOCK=0x... REGISTRY=0x... FACTORY=0x... ZAP=0x... MULTISIG=0x...

MODE=schedule forge script script/TimelockAccept.s.sol --rpc-url robinhood --sender $MULTISIG
# submit the printed scheduleTx from the multisig, wait TIMELOCK_MIN_DELAY, then
MODE=execute OP=0x<id> forge script script/TimelockAccept.s.sol --rpc-url robinhood --sender $MULTISIG
# submit the printed executeTx from the multisig
```

Verify before going further:

```sh
cast call $REGISTRY "owner()(address)" --rpc-url robinhood   # must equal $TIMELOCK
cast call $FACTORY  "owner()(address)" --rpc-url robinhood
cast call $ZAP      "owner()(address)" --rpc-url robinhood
cast call $ZAP      "paused()(bool)"   --rpc-url robinhood   # false
```

Until the timelock has accepted, the deployer is still owner. Do not create baskets or announce the
deployment before that check passes.

## Creating a basket

`createBasket` is `onlyOwner` and the owner is the timelock, so baskets are created by scheduling an
operation and executing it after the delay:

```sh
export FACTORY=0x... TIMELOCK=0x... MULTISIG=0x...
BASKETS=tech,ai,semis MODE=schedule forge script script/CreateBasket.s.sol --rpc-url robinhood --sender $MULTISIG
# submit scheduleTx from the multisig; after the delay:
MODE=execute OP=0x<id> forge script script/CreateBasket.s.sol --rpc-url robinhood --sender $MULTISIG
# submit executeTx from the multisig
```

The script derives units from live Chainlink prices when it schedules, rejects a recipe that breaches a
depth cap, falls below the 1% weight floor, fails to sum to 100%, or names a constituent with no feed, and
pins the derived recipe in `governance/ops/<id>.json`. Execution reads that file, so what goes live after
the delay is the recipe that was reviewed, not a re-derivation from wherever prices sit two days later.
Recompute depth before adding baskets: liquidity moves, and `contracts/config/robinhood-mainnet.json` is a
snapshot.

`createBasket` costs about 2.25M gas per basket (measured; `forge test --gas-report` on
`test/BasketFactory.t.sol`), so one operation carries at most ten baskets, which keeps it inside a 32M
transaction. The sixty-basket catalogue is six operations. Chain 4663 advertises a 2^50 block gas limit,
which says nothing about the per-transaction cap Arbitrum enforces; ten per operation assumes the 32M
Arbitrum default, and the testnet rehearsal is where that assumption is checked.

The label seeds the operation's salt, so re-creating a set of baskets that was created before needs a
`LABEL` of its own.

## Governance

Every parameter change goes through the timelock: schedule, wait the delay, execute. The multisig can also
cancel a scheduled operation it no longer wants.

`script/Govern.s.sol` drives any call. Build the calldata with `cast`; several targets and calldatas,
comma-separated in the same order, execute as one atomic batch:

```sh
export TIMELOCK=0x... MULTISIG=0x...
TARGETS=$ZAP CALLDATAS=$(cast calldata "setFee(uint16)" 30) LABEL="zap fee to 30 bps, 2026-09-05" \
  MODE=schedule forge script script/Govern.s.sol --rpc-url robinhood --sender $MULTISIG
# after the delay
MODE=execute OP=0x<id> forge script script/Govern.s.sol --rpc-url robinhood --sender $MULTISIG
MODE=status  OP=0x<id> forge script script/Govern.s.sol --rpc-url robinhood   # pending, ready or done
MODE=cancel  OP=0x<id> forge script script/Govern.s.sol --rpc-url robinhood --sender $MULTISIG
```

### How the multisig submits

A multisig cannot run a Foundry script, so the scripts never assume they are the signer. Every mode
simulates the call and prints the transaction the multisig has to submit — `to`, `value`, `data` — and
`MODE=schedule` also writes it to `governance/ops/<id>.json` beside the execute and cancel transactions for
the same operation. Paste it into the multisig's transaction builder, collect signatures, submit.

Run with `--sender $MULTISIG` so the simulation passes the timelock's role check, and without
`--broadcast`, since there is no key to broadcast with. `--broadcast` is for a rehearsal, or a 1-of-1 where
Foundry holds the proposer key.

Safe 1.4.1 is deployed on Robinhood Chain: `Safe` (`0x41675C099F32341bf84BFc5382aF534df5C7461a`), `SafeL2`
(`0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`) and `SafeProxyFactory`
(`0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`) all have code at their canonical addresses. Whether the
hosted Safe interface lists chain 4663 is a separate question; the Safe CLI and SDK work against the
contracts directly.

The operation files are the audit trail: every change the owner has made, in order, with what the chain
says about each available from `MODE=status`. Commit them.

| Action | Target | Call |
|---|---|---|
| Change basket fees | basket | `setFees(uint16,uint16,address)`, capped at 1% each |
| Change zap fee | zap | `setFee(uint16)`, capped at 0.5% |
| Allow-list a router | zap | `setRouter(address,bool)` |
| Allow-list a router | migrator | `setRouter(address,bool)` — a separate list from the zap's, on purpose |
| Pause or resume the zap | zap | `pause()` / `unpause()` |
| List or delist a constituent | registry | `list`, `listMany`, `delist` |
| Repoint a Chainlink feed | registry | `setFeed(address,address)` |
| Move the treasury | factory, zap | `setTreasury(address)` |

The router allow-list is the sharpest lever the protocol has. A malicious router combined with matching
calldata from a compromised front end could take a caller's funds inside that one transaction. The zap
custodies nothing between transactions, so the blast radius is one transaction, but the delay before a new
router goes live is the control that matters — never shorten it for convenience.

Redemption is deliberately not on this table. `BasketToken.redeem` has no pause switch and reads no oracle,
so holders can always exit to the underlying tokens even if the timelock is captured or lost.

## Incidents

**A constituent is paused or block-listed by the issuer.** `redeem` reverts for that leg. Holders exit with
`redeemWithSkip(shares, to, skipMask)`, which credits the frozen leg to `claimable` and pays out the rest;
they collect the remainder with `claim(token, to)` once the issuer lifts the freeze. Publish the correct
`skipMask` for the affected basket. No governance action is required, and none can speed it up.

**A Chainlink feed goes bad.** `BasketLens.nav` reverts and the quote service refuses to quote that
constituent. Schedule `setFeed(token, newFeed)` on the registry, or `setFeed(token, address(0))` to detach
it, which leaves the vault fully functional and only removes on-chain NAV.

**A router is compromised.** Schedule `setRouter(router, false)`. If the delay is too slow for the
situation, `pause()` the zap first — it is also timelocked, so the real mitigation is that the zap holds
nothing at rest. Mint and redeem in kind are unaffected by either.

**A basket needs rebalancing.** Recipes are immutable, so create a new version and publish the migration
path rather than trying to change the old one. `BasketMigrator` moves holders in one transaction and trades
only the legs that differ; both versions stay fully backed, and nobody is forced to move.

**Depth collapses under a live basket.** Recipes are immutable, so the basket cannot be repaired in place.
Users are still protected per transaction by `minAmountOut`, and the failure mode is expensive entry and
exit rather than loss. Publish the reduced capacity, and ship a replacement basket with new weights.

**The issuer burns from a vault or upgrades the token implementation.** Every Robinhood stock token is a
`BeaconProxy` behind one shared beacon, whose owner can replace the logic for all of them at once. There is
no on-chain defence. Monitor the beacon for `Upgraded`, and disclose.

## Monitoring

Watch, at minimum:

- `Upgraded` on the stock-token beacon, and `Paused` on any listed constituent
- Chainlink `updatedAt` per listed feed, alerting past the 24h heartbeat plus a margin
- `Swept` on the zap, which should be rare and always explainable
- `CallScheduled` and `Cancelled` on the timelock, so a scheduled change is never a surprise
- The scheduled `fork` CI job, which runs the mainnet fork suite daily and fails when the pinned config
  drifts from live state

Start the quote service with `-nav-snapshot-file` on the day the first basket goes live. `BasketLens.nav`
computes NAV from the feeds at call time and stores nothing, so unlike transaction history it cannot be
reconstructed afterwards. A series that was never sampled is gone.

## Deployed addresses

Record them in `docs/deployments.md` as they are created. An address that exists only in a terminal
scrollback is not recorded.
