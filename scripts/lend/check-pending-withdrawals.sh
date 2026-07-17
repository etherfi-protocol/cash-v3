#!/usr/bin/env bash
# Preflight for retiring the old modules (DeployCashLendDev leaves them enabled for
# gradual migration). Disabling the old liquid, liquidReferrer, and frax modules would
# strand any pending Cash withdrawal paying out to one of them, so run this right before
# that retirement pass. Scans every Safe's getData in parallel (in-script the same scan
# takes 20+ min because forge fetches each Safe's state sequentially).
#
# Usage: scripts/lend/check-pending-withdrawals.sh <rpc-url>
set -euo pipefail

RPC=${1:?usage: check-pending-withdrawals.sh <rpc-url>}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
DEPLOYMENTS="$REPO/deployments/dev/10/deployments.json"

addr() { python3 -c "import json; print(json.load(open('$DEPLOYMENTS'))['addresses']['$1'])"; }
CASH_MODULE=$(addr CashModule)
FACTORY=$(addr EtherFiSafeFactory)
LIQUID=$(addr EtherFiLiquidModule)
REFERRER=$(addr EtherFiLiquidModuleWithReferrer)
FRAX=$(addr FraxModule)

# A recipient shows up in the raw getData blob as a 32-byte word holding the address.
# The old module addresses cannot appear as any other SafeData field, so a hex match
# is a reliable signal; inspect any hit by hand before deploying.
PATTERN=$(printf '%s|%s|%s' "${LIQUID#0x}" "${REFERRER#0x}" "${FRAX#0x}" | tr '[:upper:]' '[:lower:]')

COUNT=$(cast call "$FACTORY" "numContractsDeployed()(uint256)" --rpc-url "$RPC")
echo "Scanning $COUNT Safes on $CASH_MODULE ..."
if [ "$COUNT" = "0" ]; then
  echo "OK: no Safes deployed"
  exit 0
fi

SAFES=$(cast call "$FACTORY" "getDeployedAddresses(uint256,uint256)(address[])" 0 "$COUNT" --rpc-url "$RPC" | tr -d '[] ' | tr ',' '\n')

# A failed call must count as a failure, not a clean safe, so retry and report per safe.
export RPC CASH_MODULE PATTERN
RESULTS=$(echo "$SAFES" | xargs -P 8 -n 1 sh -c '
  safe=$1
  for attempt in 1 2 3 4 5; do
    if out=$(cast call "$CASH_MODULE" "getData(address)" "$safe" --rpc-url "$RPC" 2>/dev/null); then
      if echo "$out" | grep -qiE "$PATTERN"; then echo "HIT $safe"; fi
      exit 0
    fi
    sleep $attempt
  done
  echo "ERROR $safe"
' _)

if echo "$RESULTS" | grep -q "^ERROR"; then
  echo "FAIL: could not read these Safes (rate limit?), rerun:"
  echo "$RESULTS" | grep "^ERROR"
  exit 1
fi
if echo "$RESULTS" | grep -q "^HIT"; then
  echo "FAIL: pending withdrawal to an old module on:"
  echo "$RESULTS" | grep "^HIT"
  exit 1
fi
echo "OK: no pending withdrawals to old modules"
