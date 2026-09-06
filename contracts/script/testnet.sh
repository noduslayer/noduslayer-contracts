#!/usr/bin/env bash
# Deploys the whole protocol to Robinhood Chain testnet, on a market of its own making, and writes what the
# quoter and the app need to point at it.
#
# Testnet mirrors nothing of mainnet: the stock tokens, feeds and Uniswap deployments all differ or are
# missing. So script/TestnetFixture.s.sol first deploys stand-ins priced from mainnet's feeds and a Uniswap
# v3 of its own, then the same Deploy, TimelockAccept and CreateBasket scripts run against them exactly as
# they will on mainnet, with CONFIG=robinhood-testnet. The result is a rehearsal that can be traded against.
#
# Usage:  ./script/testnet.sh
#   PK                      deployer key; read from ../.env when unset, and never printed
#   BASKETS=<ids>           catalogue specs to create; default every spec in config/baskets
#   TIMELOCK_MIN_DELAY=0    the timelock's delay in seconds; 0 lets this finish in one go
#   TREASURY=<address>      fee recipient; default the deployer
#   SKIP_FIXTURE=1          reuse config/robinhood-testnet.json from an earlier run instead of a new market
#   RESUME_FIXTURE=1        finish a market broadcast that stopped part-way (forge --resume), then carry on
#   SKIP_DEPLOY=1           reuse an already deployed protocol: TIMELOCK, REGISTRY, FACTORY, ZAP, MIGRATOR and
#                           LENS from the environment, DEPLOY_BLOCK optionally; the log is appended to
#   ACCEPT_OP=<id>          the ownership acceptance is already scheduled under this operation; execute it
#   SKIP_ACCEPT=1           the timelock already owns the contracts; go straight to the baskets
#   CHUNK=6                 baskets per timelock operation; the chain caps a transaction near 32M gas and a
#                           basket costs about 3.5M, so six leaves room; the list is walked in groups
#   OUT=.testnet.env        where the addresses are written, in the form the quoter's flags read
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=${RPC:-https://rpc.testnet.chain.robinhood.com}
MAINNET_URL=${MAINNET_URL:-https://rpc.mainnet.chain.robinhood.com}
MAINNET_CFG=config/robinhood-mainnet.json
CONFIG=robinhood-testnet
OUT=${OUT:-.testnet.env}
LOG=${LOG:-.testnet.log}
export OPS_DIR=governance/ops-testnet
for tool in forge cast jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

if [ -z "${PK:-}" ]; then
  [ -f ../.env ] || { echo "no PK in the environment and no ../.env to read it from" >&2; exit 1; }
  PK=$(grep -E '^PK=' ../.env | head -1 | cut -d= -f2- | tr -d "\"' ")
fi
[ -n "${PK:-}" ] || { echo "PK is empty" >&2; exit 1; }
DEPLOYER=$(cast wallet address --private-key "$PK")
TREASURY=${TREASURY:-$DEPLOYER}
DELAY=${TIMELOCK_MIN_DELAY:-0}
[ "$(cast chain-id --rpc-url "$RPC")" = 46630 ] || { echo "the RPC is not Robinhood Chain testnet (46630)" >&2; exit 1; }
echo "deployer $DEPLOYER, balance $(cast balance "$DEPLOYER" --rpc-url "$RPC" --ether) ETH on testnet"
[ "${SKIP_FIXTURE:-0}" = 1 ] || : > "$LOG"

# Gas limits are doubled over forge's estimate: this chain counts the cost of posting calldata to its
# parent in gasUsed, which a local simulation cannot see, and a limit that equals the estimate runs out.
FORGE_FLAGS=(--rpc-url "$RPC" --private-key "$PK" --slow --gas-estimate-multiplier 200 -vv)
run() { # forge script from the deployer, broadcasting one transaction at a time; everything to the log
  forge script "$@" "${FORGE_FLAGS[@]}" --broadcast >> "$LOG" 2>&1
}
resume() { # pick a stopped broadcast back up from its run file
  forge script "$@" "${FORGE_FLAGS[@]}" --resume >> "$LOG" 2>&1
}
op_state() { cast call "$TIMELOCK" 'getOperationState(bytes32)(uint8)' "$1" --rpc-url "$RPC"; }
addr_of() { grep -E "^\s*$1\s+0x[0-9a-fA-F]{40}\s*$" "$LOG" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
op_id() { awk '/== Return ==/{f=1; next} f && /bytes32/ {id=$NF; f=0} END{print id}' "$LOG"; }
wait_delay() { [ "$DELAY" -gt 0 ] && { echo "waiting out the timelock delay ($DELAY s)"; timeout "$((DELAY + 3))" tail -f /dev/null || true; }; return 0; }

if [ -z "${BASKETS:-}" ]; then
  BASKETS=$(ls config/baskets/*.json | xargs -n1 basename | sed 's/\.json$//' | paste -sd, -)
fi

if [ "${SKIP_FIXTURE:-0}" != 1 ]; then
  echo "reading prices for the baskets' constituents from mainnet's feeds"
  SYMBOLS=$(for b in ${BASKETS//,/ }; do jq -r '.symbols[]' "config/baskets/$b.json"; done | sort -u | paste -sd, -)
  PRICES=""
  for sym in ${SYMBOLS//,/ }; do
    feed=$(jq -r --arg s "$sym" '.stockFeeds[(.stockSymbols | index($s))]' $MAINNET_CFG)
    [ "$feed" != "0x0000000000000000000000000000000000000000" ] || { echo "$sym has no feed on mainnet" >&2; exit 1; }
    price=$(cast call "$feed" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$MAINNET_URL" | sed -n 2p | awk '{print $1}')
    PRICES="${PRICES:+$PRICES,}$price"
  done
  ETH_PRICE=$(cast call "$(jq -r .ethUsdFeed $MAINNET_CFG)" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$MAINNET_URL" | sed -n 2p | awk '{print $1}')
  echo "  $SYMBOLS"
  if [ "${RESUME_FIXTURE:-0}" = 1 ]; then
    echo "resuming the market broadcast"
    SYMBOLS=$SYMBOLS PRICES=$PRICES ETH_PRICE=$ETH_PRICE OUT=$CONFIG resume script/TestnetFixture.s.sol:TestnetFixture
  else
    echo "deploying the market: Uniswap v3, $(echo "$SYMBOLS" | tr , '\n' | wc -l | tr -d ' ') tokens and feeds, USDG, WETH and their pools"
    SYMBOLS=$SYMBOLS PRICES=$PRICES ETH_PRICE=$ETH_PRICE OUT=$CONFIG run script/TestnetFixture.s.sol:TestnetFixture
  fi
fi
USDG=$(jq -r .usdg "config/$CONFIG.json"); WETH=$(jq -r .weth "config/$CONFIG.json")
[ -n "$USDG" ] && [ "$USDG" != null ] || { echo "no testnet config written; see $LOG" >&2; exit 1; }

if [ "${SKIP_DEPLOY:-0}" != 1 ]; then
  echo "deploying the protocol"
  MULTISIG=$DEPLOYER TREASURY=$TREASURY TIMELOCK_MIN_DELAY=$DELAY CONFIG=$CONFIG run script/Deploy.s.sol
  TIMELOCK=$(addr_of TimelockController); REGISTRY=$(addr_of StockRegistry); FACTORY=$(addr_of BasketFactory)
  ZAP=$(addr_of BasketZap); MIGRATOR=$(addr_of BasketMigrator); LENS=$(addr_of BasketLens)
  for v in TIMELOCK REGISTRY FACTORY ZAP MIGRATOR LENS; do
    [ -n "${!v}" ] || { echo "could not read $v from the deploy output; see $LOG" >&2; exit 1; }
  done
else
  echo "reusing the deployed protocol named in the environment"
  for v in TIMELOCK REGISTRY FACTORY ZAP MIGRATOR LENS; do
    [ -n "${!v:-}" ] || { echo "SKIP_DEPLOY=1 needs $v" >&2; exit 1; }
  done
fi
export TIMELOCK REGISTRY FACTORY ZAP MIGRATOR MULTISIG=$DEPLOYER
DEPLOY_BLOCK=${DEPLOY_BLOCK:-$(jq -r '[.receipts[].blockNumber] | min' broadcast/Deploy.s.sol/46630/run-latest.json | cast to-dec)}

if [ "${SKIP_ACCEPT:-0}" != 1 ]; then
echo "accepting ownership through the timelock"
if [ -n "${ACCEPT_OP:-}" ]; then
  OP=$ACCEPT_OP
else
  MODE=schedule LABEL="testnet accept" run script/TimelockAccept.s.sol
  OP=$(op_id); [ -n "$OP" ] || { echo "no operation id from TimelockAccept; see $LOG" >&2; exit 1; }
  wait_delay
fi
MODE=execute OP=$OP run script/TimelockAccept.s.sol
fi
[ "$(cast call "$FACTORY" 'owner()(address)' --rpc-url "$RPC")" = "$(cast to-check-sum-address "$TIMELOCK")" ] \
  || { echo "the timelock did not take ownership" >&2; exit 1; }

echo "creating baskets: $BASKETS"
# CreateBasket schedules one operation per run and refuses more than CHUNK baskets in it, so the list is
# walked in groups: schedule a group, wait out the delay, execute it, next group.
chunk=${CHUNK:-6}
ids=(${BASKETS//,/ })
group_no=0
for ((i = 0; i < ${#ids[@]}; i += chunk)); do
  group_no=$((group_no + 1))
  group=$(IFS=,; echo "${ids[*]:i:chunk}")
  echo "  operation $group_no: $group"
  MODE=schedule LABEL="testnet baskets $group_no" BASKETS=$group CONFIG=$CONFIG CHUNK=$chunk run script/CreateBasket.s.sol
  OP=$(op_id); [ -n "$OP" ] || { echo "no operation id from CreateBasket; see $LOG" >&2; exit 1; }
  wait_delay
  MODE=execute OP=$OP BASKETS=$group CONFIG=$CONFIG CHUNK=$chunk run script/CreateBasket.s.sol
done
BASKET_LIST=$(cast call "$FACTORY" 'baskets()(address[])' --rpc-url "$RPC" | tr -d '[] ')
[ -n "$BASKET_LIST" ] || { echo "the factory lists no baskets" >&2; exit 1; }

echo "minting 1,000,000 test USDG to the deployer"
cast send "$USDG" 'mint(address,uint256)' "$DEPLOYER" 1000000000000 --private-key "$PK" --rpc-url "$RPC" >/dev/null

cat > "$OUT" <<ENV
# Written by script/testnet.sh. Robinhood Chain testnet (46630); every address below is a stand-in or a
# rehearsal deployment, never mainnet's.
TESTNET_RPC=$RPC
TESTNET_CHAIN_ID=46630
TESTNET_DEPLOYER=$DEPLOYER
TESTNET_TREASURY=$TREASURY
TESTNET_TIMELOCK=$TIMELOCK
TESTNET_REGISTRY=$REGISTRY
TESTNET_USDG=$USDG
TESTNET_WETH=$WETH
TESTNET_BASKETS=$BASKET_LIST
TESTNET_DEPLOY_BLOCK=$DEPLOY_BLOCK
QUOTER_RPC=$RPC
QUOTER_CONFIG=$PWD/config/$CONFIG.json
QUOTER_FACTORY=$FACTORY
QUOTER_ZAP=$ZAP
QUOTER_LENS=$LENS
QUOTER_MIGRATOR=$MIGRATOR
QUOTER_INDEX_FROM_BLOCK=$DEPLOY_BLOCK
QUOTER_BLOCKED_COUNTRIES=
ENV
echo
echo "testnet deployment complete; addresses in $OUT"
echo "  timelock  $TIMELOCK"
echo "  registry  $REGISTRY"
echo "  factory   $FACTORY"
echo "  zap       $ZAP"
echo "  migrator  $MIGRATOR"
echo "  lens      $LENS"
echo "  usdg      $USDG"
echo "  weth      $WETH"
echo "  baskets   $(echo "$BASKET_LIST" | tr , '\n' | wc -l | tr -d ' ') created from block $DEPLOY_BLOCK"
echo "  balance left $(cast balance "$DEPLOYER" --rpc-url "$RPC" --ether) ETH"
