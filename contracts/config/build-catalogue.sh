#!/usr/bin/env bash
# Collects every basket spec into one file a consumer can vendor, keyed by the spec's file name.
#
# The quote service serves baskets by on-chain address and matches them to these entries by symbol, so a
# front end can show a basket's theme and description, and list what is in the catalogue but not yet
# created. Regenerate after editing any spec; CI fails when this file is stale.
set -euo pipefail
cd "$(dirname "$0")/.."

for f in config/baskets/[!_]*.json; do
  jq --arg id "$(basename "$f" .json)" '{id: $id} + .' "$f"
done | jq -s '{generatedBy: "config/build-catalogue.sh", baskets: .}' > config/catalogue.json

echo "catalogue: $(jq '.baskets | length' config/catalogue.json) baskets"
