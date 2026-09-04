#!/usr/bin/env bash
# Exports the ABI surface consumers depend on, plus the function selectors derived from it.
#
# Anything outside this repository that encodes calls to these contracts — the quoter, a front end — pins
# itself to this artifact. Regenerate it whenever an external signature changes, and the consumer's own
# tests will fail until it is updated, which is the point.
set -euo pipefail
cd "$(dirname "$0")/.."
forge build >/dev/null

CONTRACTS=(BasketToken BasketFactory BasketZap BasketLens StockRegistry)
for c in "${CONTRACTS[@]}"; do
  jq '.abi' "out/$c.sol/$c.json" > "abi/$c.json"
done

# Selectors for every external function across those ABIs, keyed by signature.
{
  echo '{'
  echo '  "generatedBy": "abi/export.sh",'
  echo '  "selectors": {'
  first=1
  for c in "${CONTRACTS[@]}"; do
    jq -r '.[] | select(.type=="function") |
      "\(.name)(" + ([.inputs[] | if .type=="tuple" then "(" + ([.components[].type] | join(",")) + ")"
      elif .type=="tuple[]" then "(" + ([.components[].type] | join(",")) + ")[]"
      else .type end] | join(",")) + ")"' "abi/$c.json"
  done | sort -u | while read -r sig; do
    [ $first -eq 0 ] && echo ','
    first=0
    printf '    "%s": "%s"' "$sig" "$(cast sig "$sig")"
  done
  echo
  echo '  }'
  echo '}'
} > abi/selectors.json

echo "exported $(ls abi/*.json | grep -vc selectors) ABIs and $(jq '.selectors | length' abi/selectors.json) selectors"
