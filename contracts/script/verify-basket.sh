#!/usr/bin/env bash
# Verifies a BasketToken's source on Blockscout.
#
# The factory deploys baskets with `new`, so the deploy script's --verify never sees them. This rebuilds the
# constructor arguments from what the basket itself reports and submits the source against them.
#
# Usage: BASKET=0x... ./script/verify-basket.sh
# Optional: RPC (robinhood), VERIFIER_URL (https://robinhoodchain.blockscout.com/api)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${BASKET:?BASKET=0x... is required}"
RPC=${RPC:-robinhood}
VERIFIER_URL=${VERIFIER_URL:-https://robinhoodchain.blockscout.com/api}

call() { cast call "$BASKET" "$1" --rpc-url "$RPC" "${@:2}"; }

name=$(call "name()(string)" --json | jq -r '.[0]')
symbol=$(call "symbol()(string)" --json | jq -r '.[0]')
mint_fee=$(call "mintFeeBps()(uint16)")
redeem_fee=$(call "redeemFeeBps()(uint16)")
# cast prints `[(0x…, 200000000000000000 [2e17]), …]`; abi-encode wants `[(0x…,200000000000000000),…]`.
# Parsed as text rather than JSON so units above 2^53 keep every digit.
recipe=$(call "constituents()((address,uint256)[])" | sed -E 's/ \[[^]]*\]//g; s/ //g')
chain=$(cast chain-id --rpc-url "$RPC")

args=$(cast abi-encode "constructor(string,string,(address,uint256)[],uint16,uint16)" \
  "$name" "$symbol" "$recipe" "$mint_fee" "$redeem_fee")

echo "verifying $symbol ($name) at $BASKET on chain $chain"
forge verify-contract "$BASKET" src/BasketToken.sol:BasketToken \
  --chain "$chain" --verifier blockscout --verifier-url "$VERIFIER_URL" \
  --constructor-args "$args" --watch
