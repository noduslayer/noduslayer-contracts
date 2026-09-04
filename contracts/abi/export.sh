#!/usr/bin/env bash
# Exports the ABI surface consumers depend on, plus the function selectors derived from it.
#
# Anything outside this repository that encodes calls to these contracts — the quoter, a front end — pins
# itself to this artifact. Regenerate it whenever an external signature changes, and the consumer's own
# tests will fail until it is updated, which is the point.
set -euo pipefail
cd "$(dirname "$0")/.."
forge build >/dev/null

CONTRACTS=(BasketToken BasketFactory BasketZap BasketMigrator BasketLens StockRegistry)
for c in "${CONTRACTS[@]}"; do
  jq '.abi' "out/$c.sol/$c.json" > "abi/$c.json"
done

# Renders one ABI entry as its canonical signature, tuples included.
SIG='"\(.name)(" + ([.inputs[] | if .type=="tuple" then "(" + ([.components[].type] | join(",")) + ")"
  elif .type=="tuple[]" then "(" + ([.components[].type] | join(",")) + ")[]"
  else .type end] | join(",")) + ")"'

# Writes {"<key>": {signature: selector, ...}} for every unique signature on stdin.
emit() {
  local key=$1 first=1
  echo '{'
  echo '  "generatedBy": "abi/export.sh",'
  echo "  \"$key\": {"
  sort -u | while read -r sig; do
    [ $first -eq 0 ] && echo ','
    first=0
    printf '    "%s": "%s"' "$sig" "$(cast sig "$sig")"
  done
  echo
  echo '  }'
  echo '}'
}

# Selectors for every external function across those ABIs, keyed by signature.
for c in "${CONTRACTS[@]}"; do
  jq -r ".[] | select(.type==\"function\") | $SIG" "abi/$c.json"
done | emit selectors > abi/selectors.json

# Every custom error those contracts can revert with, plus the two the compiler raises itself. A consumer
# that turns revert data into a message pins itself to this the way it pins selectors.
{
  printf 'Error(string)\nPanic(uint256)\n'
  for c in "${CONTRACTS[@]}"; do
    jq -r ".[] | select(.type==\"error\") | $SIG" "abi/$c.json"
  done
} | emit errors > abi/errors.json

echo "exported ${#CONTRACTS[@]} ABIs, $(jq '.selectors | length' abi/selectors.json) selectors and $(jq '.errors | length' abi/errors.json) errors"
