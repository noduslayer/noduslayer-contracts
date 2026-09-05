#!/usr/bin/env bash
# Fails when line coverage of src/ falls under a floor. Reads the summary `forge coverage` prints.
#
# Usage: forge coverage --report summary --no-match-coverage 'script/' | ./script/coverage-floor.sh 97
set -euo pipefail
floor=${1:?usage: coverage-floor.sh <percent>}

total=$(grep -E '^\| Total ' | head -1 | awk -F'|' '{print $3}' | tr -d ' %' | cut -d'(' -f1)
[ -n "$total" ] || { echo "no coverage total found" >&2; exit 2; }

if awk -v t="$total" -v f="$floor" 'BEGIN { exit !(t + 0 < f + 0) }'; then
  echo "line coverage ${total}% is under the ${floor}% floor" >&2
  exit 1
fi
echo "line coverage ${total}% (floor ${floor}%)"
