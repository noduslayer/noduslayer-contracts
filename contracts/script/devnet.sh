#!/usr/bin/env bash
# Stands up a local fork of Robinhood Chain with the protocol deployed, ownership accepted through a
# zero-delay timelock and a few baskets created from live feed prices, for end-to-end runs of the quoter and
# the front end. Nothing here touches mainnet: the fork reads from it and every write stays local.
#
# Usage:  ./script/devnet.sh
#   BASKETS=tech,ai   catalogue specs to create (config/baskets/<name>.json)
#   FORK_URL=...      mainnet RPC to fork (default the public endpoint)
#   FORK_BLOCK=<n>    pin the fork block for a reproducible run
#   PORT=8545         anvil's port; an anvil already listening there is reused
#   OUT=.devnet.env   where the addresses are written, in the form the quoter's flags read
#
# Anvil keeps running when this exits; `kill $(grep DEVNET_ANVIL_PID .devnet.env | cut -d= -f2)` stops it.
set -euo pipefail
cd "$(dirname "$0")/.."

FORK_URL=${FORK_URL:-https://rpc.mainnet.chain.robinhood.com}
PORT=${PORT:-8545}
RPC=http://127.0.0.1:$PORT
BASKETS=${BASKETS:-tech,ai}
OUT=${OUT:-.devnet.env}
LOG=${LOG:-.devnet.log}
export OPS_DIR=governance/ops-devnet

# anvil's deterministic accounts: 0 deploys and stands in for the multisig, 1 is the treasury, 2 is a user.
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
TREASURY=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
USER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
USER_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

for tool in anvil cast forge jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done
: > "$LOG"

# A devnet broadcast is not a record of anything; whatever this run writes under broadcast/ is removed
# again, so a real deployment's files are never confused with a rehearsal's.
before=$(mktemp)
find broadcast -type f 2>/dev/null | sort > "$before" || true
cleanup() {
  if [ -d broadcast ]; then
    find broadcast -type f | sort | comm -13 "$before" - | while read -r f; do rm -f "$f"; done
    find broadcast -type d -empty -delete 2>/dev/null || true
  fi
  rm -f "$before"
}
trap cleanup EXIT

ANVIL_PID=
if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "using the node already listening on :$PORT"
else
  echo "starting anvil as a fork of $FORK_URL on :$PORT"
  # shellcheck disable=SC2086
  nohup anvil --fork-url "$FORK_URL" --port "$PORT" ${FORK_BLOCK:+--fork-block-number $FORK_BLOCK} \
    --silent > .devnet-anvil.log 2>&1 &
  ANVIL_PID=$!
  disown
  for _ in $(seq 1 120); do
    cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 0.5
  done
fi
CHAIN=$(cast chain-id --rpc-url "$RPC")
[ "$CHAIN" = 4663 ] || { echo "node reports chain $CHAIN, want 4663 (a fork keeps mainnet's id)" >&2; exit 1; }

run() { # forge script from the deployer, broadcasting; everything to the log
  forge script "$@" --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast -vv >> "$LOG" 2>&1
}
addr_of() { grep -E "^\s*$1\s+0x[0-9a-fA-F]{40}\s*$" "$LOG" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
# The operation id is the script's return value; forge prints it under "== Return ==". The last one in the
# log is the run that just finished.
op_id() { awk '/== Return ==/{f=1; next} f && /bytes32/ {id=$NF; f=0} END{print id}' "$LOG"; }

echo "deploying"
MULTISIG=$DEPLOYER TREASURY=$TREASURY TIMELOCK_MIN_DELAY=0 CONFIG=robinhood-mainnet \
  run script/Deploy.s.sol
TIMELOCK=$(addr_of TimelockController); REGISTRY=$(addr_of StockRegistry); FACTORY=$(addr_of BasketFactory)
ZAP=$(addr_of BasketZap); MIGRATOR=$(addr_of BasketMigrator); LENS=$(addr_of BasketLens)
for v in TIMELOCK REGISTRY FACTORY ZAP MIGRATOR LENS; do
  [ -n "${!v}" ] || { echo "could not read $v from the deploy output; see $LOG" >&2; exit 1; }
done
export TIMELOCK REGISTRY FACTORY ZAP MIGRATOR

echo "accepting ownership through the timelock"
MODE=schedule LABEL="devnet accept" run script/TimelockAccept.s.sol
OP=$(op_id)
[ -n "$OP" ] || { echo "no operation id from TimelockAccept; see $LOG" >&2; exit 1; }
MODE=execute OP=$OP run script/TimelockAccept.s.sol
[ "$(cast call "$FACTORY" 'owner()(address)' --rpc-url "$RPC")" = "$(cast to-check-sum-address "$TIMELOCK")" ] \
  || { echo "the timelock did not take ownership" >&2; exit 1; }

echo "creating baskets: $BASKETS"
MODE=schedule LABEL="devnet baskets" BASKETS=$BASKETS CONFIG=robinhood-mainnet run script/CreateBasket.s.sol
OP=$(op_id)
[ -n "$OP" ] || { echo "no operation id from CreateBasket; see $LOG" >&2; exit 1; }
MODE=execute OP=$OP BASKETS=$BASKETS CONFIG=robinhood-mainnet run script/CreateBasket.s.sol
BASKET_LIST=$(cast call "$FACTORY" 'baskets()(address[])' --rpc-url "$RPC" | tr -d '[] ' )
[ -n "$BASKET_LIST" ] || { echo "the factory lists no baskets" >&2; exit 1; }

echo "funding the user with USDG"
USDG=$(jq -r .usdg config/robinhood-mainnet.json); WETH=$(jq -r .weth config/robinhood-mainnet.json)
PM=$(jq -r .uniswap.poolManager config/robinhood-mainnet.json)
HELD=$(cast call "$USDG" 'balanceOf(address)(uint256)' "$PM" --rpc-url "$RPC" | awk '{print $1}')
[ "$HELD" -ge 100000000000 ] || { echo "the pool manager holds only $HELD USDG units on this fork" >&2; exit 1; }
cast rpc anvil_impersonateAccount "$PM" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$PM" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
cast send "$USDG" 'transfer(address,uint256)' "$USER" 50000000000 --from "$PM" --unlocked --rpc-url "$RPC" >/dev/null
cast rpc anvil_stopImpersonatingAccount "$PM" --rpc-url "$RPC" >/dev/null

cat > "$OUT" <<ENV
# Written by script/devnet.sh. A local fork of Robinhood Chain; every address below is local to it.
DEVNET_RPC=$RPC
DEVNET_CHAIN_ID=4663
DEVNET_ANVIL_PID=$ANVIL_PID
DEVNET_TIMELOCK=$TIMELOCK
DEVNET_REGISTRY=$REGISTRY
DEVNET_TREASURY=$TREASURY
DEVNET_DEPLOYER=$DEPLOYER
DEVNET_USER=$USER
DEVNET_USER_KEY=$USER_KEY
DEVNET_USDG=$USDG
DEVNET_WETH=$WETH
DEVNET_BASKETS=$BASKET_LIST
QUOTER_RPC=$RPC
QUOTER_FACTORY=$FACTORY
QUOTER_ZAP=$ZAP
QUOTER_LENS=$LENS
QUOTER_MIGRATOR=$MIGRATOR
QUOTER_CORS_ORIGINS=http://localhost:3000
QUOTER_BLOCKED_COUNTRIES=
QUOTER_NAV_INTERVAL=30s
QUOTER_INDEX_INTERVAL=5s
ENV

echo
echo "devnet ready — $OUT"
echo "  timelock  $TIMELOCK"
echo "  registry  $REGISTRY"
echo "  factory   $FACTORY"
echo "  zap       $ZAP"
echo "  migrator  $MIGRATOR"
echo "  lens      $LENS"
echo "  baskets   $BASKET_LIST"
echo "  user      $USER (50,000 USDG, 10,000 ETH)"
echo "next: set -a; . $OUT; set +a; go run ./cmd/quoter      # in noduslayer-quoter"
