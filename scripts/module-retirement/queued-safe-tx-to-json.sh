#!/usr/bin/env bash
# Read-only: fetches the transaction queued at <nonce> for the governance Safe (same address on Optimism
# and Ethereum) from the Safe transaction service and writes it as a flat Transaction Builder JSON (one entry per inner call), so a
# fork simulation can replay it call by call as the Safe. A MultiSend wrapper is unpacked; a direct call
# is written as a single entry. Nothing is signed or sent.
#
# Usage: scripts/module-retirement/queued-safe-tx-to-json.sh <chain-id: 10|1> <nonce> <out.json>
set -euo pipefail
CHAIN=${1:?usage: queued-safe-tx-to-json.sh <chain-id: 10|1> <nonce> <out.json>}
NONCE=${2:?usage: queued-safe-tx-to-json.sh <chain-id: 10|1> <nonce> <out.json>}
OUT=${3:?usage: queued-safe-tx-to-json.sh <chain-id: 10|1> <nonce> <out.json>}
SAFE=0xA6cf33124cb342D1c604cAC87986B965F428AAC4
case "$CHAIN" in
  10) SLUG=oeth ;;
  1) SLUG=eth ;;
  *) echo "unsupported chain $CHAIN" >&2; exit 1 ;;
esac
URL="https://api.safe.global/tx-service/$SLUG/api/v1/safes/$SAFE/multisig-transactions/?nonce=$NONCE"
mkdir -p "$(dirname "$OUT")"
curl -sfL "$URL" | python3 -c '
import json, sys
d = json.load(sys.stdin)
res = d["results"]
if len(res) != 1:
    sys.exit("expected exactly one transaction at this nonce, found %d" % len(res))
t = res[0]
if t["isExecuted"]:
    sys.exit("nonce already executed")
calls = []
if t["operation"] == 1:  # delegatecall into MultiSendCallOnly: unpack [op(1) to(20) value(32) len(32) data]
    raw = bytes.fromhex(t["data"][2:])
    sel, rest = raw[:4], raw[4:]
    assert sel.hex() == "8d80ff0a", "not multiSend(bytes)"
    ln = int.from_bytes(rest[32:64], "big")
    p, i = rest[64:64 + ln], 0
    while i < len(p):
        assert p[i] == 0, "inner delegatecall not expected"
        to = "0x" + p[i + 1:i + 21].hex()
        val = int.from_bytes(p[i + 21:i + 53], "big")
        n = int.from_bytes(p[i + 53:i + 85], "big")
        calls.append({"to": to, "value": str(val), "data": "0x" + p[i + 85:i + 85 + n].hex()})
        i += 85 + n
else:
    calls.append({"to": t["to"], "value": str(t["value"]), "data": t["data"] or "0x"})
json.dump({"chainId": "'$CHAIN'", "safeAddress": "'$SAFE'", "safeTxHash": t["safeTxHash"], "transactions": calls}, sys.stdout, indent=1)
' > "$OUT"
echo "wrote $OUT"
