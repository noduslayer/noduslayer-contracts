#!/usr/bin/env bash
# Stands up a local chain with the protocol deployed, ownership accepted through a zero-delay timelock and
# baskets created from the catalogue, for end-to-end runs of the quoter and the front end.
#
# The chain is a local anvil with Robinhood Chain's id, not a fork: the public RPC keeps state for roughly
# ten minutes of blocks, so a fork fails on the first storage slot it has not seen once it is that old.
# Instead mainnet's Uniswap v3 factory, router, quoter, WETH9 and Multicall3 bytecode is placed at mainnet's
# addresses — the router and quoter keep the factory and WETH addresses baked into them — and
# script/Devnet.s.sol deploys stock tokens, feeds, a USDG and deep pools against USDG and WETH, priced from
# mainnet's feeds at run time. Nothing here touches mainnet beyond reading it.
#
# Usage:  ./script/devnet.sh
#   BASKETS=tech,ai        catalogue specs to create; their constituents are the tokens deployed
#   MAINNET_URL=...        where bytecode and prices are read from (default the public endpoint)
#   PORT=8545              anvil's port; an anvil already listening there is reused
#   OUT=.devnet.env        where the addresses are written, in the form the quoter's flags read
#
# Anvil keeps running when this exits; `kill $(grep DEVNET_ANVIL_PID .devnet.env | cut -d= -f2)` stops it.
set -euo pipefail
cd "$(dirname "$0")/.."

MAINNET_URL=${MAINNET_URL:-https://rpc.mainnet.chain.robinhood.com}
PORT=${PORT:-8545}
RPC=http://127.0.0.1:$PORT
BASKETS=${BASKETS:-tech,ai}
OUT=${OUT:-.devnet.env}
LOG=${LOG:-.devnet.log}
CONFIG=robinhood-devnet
MAINNET_CFG=config/robinhood-mainnet.json
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
  echo "starting anvil on :$PORT"
  nohup anvil --chain-id 4663 --port "$PORT" --balance 1000000 --gas-limit 60000000 --silent > .devnet-anvil.log 2>&1 &
  ANVIL_PID=$!
  disown
  for _ in $(seq 1 60); do
    cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break
    sleep 0.5
  done
fi
CHAIN=$(cast chain-id --rpc-url "$RPC")
[ "$CHAIN" = 4663 ] || { echo "node reports chain $CHAIN, want 4663" >&2; exit 1; }
[ "$(cast block-number --rpc-url "$RPC")" -lt 10000 ] || { echo "that node is not a fresh devnet; refusing" >&2; exit 1; }

# Simulations must read the node, not forge's RPC cache: this chain id and block height recur on every fresh
# anvil, and a cached reading from an earlier run would describe code that is no longer there.
run() { # forge script from the deployer, broadcasting; everything to the log
  forge script "$@" --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" --broadcast --no-storage-caching -vv >> "$LOG" 2>&1
}
addr_of() { grep -E "^\s*$1\s+0x[0-9a-fA-F]{40}\s*$" "$LOG" | tail -1 | grep -oE '0x[0-9a-fA-F]{40}'; }
# The operation id is the script's return value; forge prints it under "== Return ==". The last one in the
# log is the run that just finished.
op_id() { awk '/== Return ==/{f=1; next} f && /bytes32/ {id=$NF; f=0} END{print id}' "$LOG"; }
word() { cast to-uint256 "$1"; } # a 32-byte word from a number or an address

echo "placing mainnet's Uniswap v3 and Multicall3 bytecode, and a WETH at mainnet's WETH address"
FACTORY_V3=$(jq -r .uniswap.v3Factory $MAINNET_CFG); ROUTER=$(jq -r .uniswap.swapRouter02 $MAINNET_CFG)
QUOTER_V2=$(jq -r .uniswap.quoterV2 $MAINNET_CFG); WETH=$(jq -r .weth $MAINNET_CFG)
MULTICALL3=0xcA11bde05977b3631167028862bE2a173976CA11
for a in "$FACTORY_V3" "$ROUTER" "$QUOTER_V2" "$MULTICALL3"; do
  code=$(cast code "$a" --rpc-url "$MAINNET_URL")
  [ "$code" != "0x" ] || { echo "no code at $a on mainnet" >&2; exit 1; }
  cast rpc anvil_setCode "$a" "$code" --rpc-url "$RPC" >/dev/null
done
# Mainnet's WETH is an upgradeable proxy; its storage cannot be copied, so a plain WETH with constant
# metadata takes the address the router and quoter expect.
forge build >/dev/null 2>&1
cast rpc anvil_setCode "$WETH" "$(forge inspect DevnetWETH deployedBytecode)" --rpc-url "$RPC" >/dev/null
[ "$(cast call "$WETH" 'decimals()(uint8)' --rpc-url "$RPC")" = 18 ] || { echo "WETH stand-in did not take" >&2; exit 1; }
# The factory's owner and fee tiers live in storage the bytecode does not carry. Their slots were read off
# mainnet's factory (owner at 3, feeAmountTickSpacing at 4; it is not the canonical layout) and are checked
# below, so a factory that moved them fails here rather than at createPool.
cast rpc anvil_setStorageAt "$FACTORY_V3" "$(word 3)" "$(word "$DEPLOYER")" --rpc-url "$RPC" >/dev/null
for pair in 100:1 500:10 3000:60 10000:200; do
  fee=${pair%%:*}; spacing=${pair##*:}
  cast rpc anvil_setStorageAt "$FACTORY_V3" "$(cast index uint24 "$fee" 4)" "$(word "$spacing")" --rpc-url "$RPC" >/dev/null
done
[ "$(cast call "$FACTORY_V3" 'feeAmountTickSpacing(uint24)(int24)' 500 --rpc-url "$RPC")" = 10 ] \
  || { echo "the factory's storage layout is not the one this script expects" >&2; exit 1; }
[ "$(cast call "$FACTORY_V3" 'owner()(address)' --rpc-url "$RPC")" = "$DEPLOYER" ] \
  || { echo "the factory's owner slot is not the one this script expects" >&2; exit 1; }

echo "reading prices for the baskets' constituents from mainnet's feeds"
SYMBOLS=$(for b in ${BASKETS//,/ }; do jq -r '.symbols[]' "config/baskets/$b.json"; done | sort -u | paste -sd, -)
PRICES=""
for sym in ${SYMBOLS//,/ }; do
  feed=$(jq -r --arg s "$sym" '.stockFeeds[(.stockSymbols | index($s))]' $MAINNET_CFG)
  [ "$feed" != "0x0000000000000000000000000000000000000000" ] || { echo "$sym has no feed; pick baskets whose constituents are priced" >&2; exit 1; }
  price=$(cast call "$feed" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$MAINNET_URL" | sed -n 2p | awk '{print $1}')
  PRICES="${PRICES:+$PRICES,}$price"
done
ETH_PRICE=$(cast call "$(jq -r .ethUsdFeed $MAINNET_CFG)" 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url "$MAINNET_URL" | sed -n 2p | awk '{print $1}')
echo "  $SYMBOLS"

echo "deploying tokens, feeds, USDG and pools"
SYMBOLS=$SYMBOLS PRICES=$PRICES ETH_PRICE=$ETH_PRICE OUT=$CONFIG run script/Devnet.s.sol:Devnet
USDG=$(jq -r .usdg "config/$CONFIG.json")
[ -n "$USDG" ] && [ "$USDG" != null ] || { echo "no devnet config written; see $LOG" >&2; exit 1; }

echo "deploying the protocol"
MULTISIG=$DEPLOYER TREASURY=$TREASURY TIMELOCK_MIN_DELAY=0 CONFIG=$CONFIG run script/Deploy.s.sol
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
MODE=schedule LABEL="devnet baskets" BASKETS=$BASKETS CONFIG=$CONFIG run script/CreateBasket.s.sol
OP=$(op_id)
[ -n "$OP" ] || { echo "no operation id from CreateBasket; see $LOG" >&2; exit 1; }
MODE=execute OP=$OP BASKETS=$BASKETS CONFIG=$CONFIG run script/CreateBasket.s.sol
BASKET_LIST=$(cast call "$FACTORY" 'baskets()(address[])' --rpc-url "$RPC" | tr -d '[] ')
[ -n "$BASKET_LIST" ] || { echo "the factory lists no baskets" >&2; exit 1; }

echo "funding the user"
cast send "$USDG" 'mint(address,uint256)' "$USER" 50000000000 --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null

cat > "$OUT" <<ENV
# Written by script/devnet.sh. A local chain with Robinhood Chain's id; every address below is local to it.
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
QUOTER_CONFIG=$PWD/config/$CONFIG.json
QUOTER_FACTORY=$FACTORY
QUOTER_ZAP=$ZAP
QUOTER_LENS=$LENS
QUOTER_MIGRATOR=$MIGRATOR
QUOTER_CORS_ORIGINS=http://localhost:3000,http://127.0.0.1:3000,http://localhost:3100,http://127.0.0.1:3100
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
echo "  usdg      $USDG"
echo "  baskets   $BASKET_LIST"
echo "  user      $USER (50,000 USDG, 1,000,000 ETH)"
echo "next: set -a; . $OUT; set +a; go run ./cmd/quoter      # in noduslayer-quoter"
