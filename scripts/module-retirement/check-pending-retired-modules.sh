#!/usr/bin/env bash
# Preflight for retiring the superseded Optimism Cash modules (old Liquid, Liquid with referrer,
# Stargate, BeHYPE stake, Midas). Read-only: eth_getLogs and eth_call only, nothing is signed or sent.
#
# Why this exists: a Cash withdrawal requested by a module pays out to the module itself. Once the
# module is removed from the withdraw-requester set, processWithdrawal becomes callable by anyone and
# the module has no sweep, so a pending withdrawal (or pending bridge) on a retired module strands
# the funds. Retirement therefore needs ZERO pending withdrawals and bridges on every retired module.
#
# Why events: there are ~540k Safes, so scanning getData per Safe is not practical on a public RPC.
# Instead this scans CashEventEmitter WithdrawalRequested / WithdrawalProcessed / WithdrawalCancelled
# (the recipient is indexed) for every retired module, keeps each (safe, module) pair whose latest event
# is a request, and confirms each suspect against live state:
#   - getPendingBridge(safe) on every module that has one (Liquid, Liquid with referrer, Stargate)
#   - CashModule.getData(safe).pendingWithdrawalRequest.recipient
# Only the Liquid, Liquid with referrer and Stargate modules ever request a withdrawal. BeHYPE and Midas
# act directly on the Safe and keep no pending state, so they are scanned for completeness.
#
# Usage:
#   scripts/module-retirement/check-pending-retired-modules.sh [state-rpc] [logs-rpc]
#   OPTIMISM_RPC / LOGS_RPC env vars are used when the arguments are omitted. The logs RPC must serve
#   historical eth_getLogs (the default does; publicnode's free tier does not).
# Exit code 0 only when nothing is pending. The last line is always PENDING_COUNT=<n>.
set -euo pipefail
exec python3 - "${1:-${OPTIMISM_RPC:-https://optimism-rpc.publicnode.com}}" "${2:-${LOGS_RPC:-https://optimism.gateway.tenderly.co}}" <<'PY'
import json, subprocess, sys, urllib.request

STATE_RPC, LOGS_RPC = sys.argv[1], sys.argv[2]
FROM_BLOCK = 149_000_000  # before the first module-recipient withdrawal ever requested (block ~149.8M)
EMITTER = "0x380B2e96799405be6e3D965f4044099891881acB"  # CashEventEmitter
CASH_MODULE = "0x7Ca0b75E67E33c0014325B739A8d019C4FE445F0"

# name -> (address, has getPendingBridge)
MODULES = {
    "EtherFiLiquidModule": ("0x427fDe7FF5D685e76f572BDFb896184a2048f232", True),
    "EtherFiLiquidModuleWithReferrer": ("0xA051246A613E3216DD90402453D3B8aD63E71Cd1", True),
    "StargateModule": ("0x865a756d15e40D1D38595a39F29867518594182E", True),
    "BeHYPEStakeModule": ("0x46E9aF4DC3D4535AfCbeb408Db564D729F527bD8", False),
    "MidasModule": ("0x80b14dC43d257C6bC7487249095F1435d43fC591", False),
    # Already unlisted; scanned so its history is visible and it cannot hide a pending request.
    "StargateModule (pre-taxi, unlisted)": ("0xee77DEB6991f5d5CcAE5a327debA32d292E85c1c", True),
}


def rpc(url, method, params):
    req = urllib.request.Request(url, json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
                                 {"Content-Type": "application/json", "User-Agent": "module-retirement-preflight"})
    return json.load(urllib.request.urlopen(req, timeout=60))


def keccak(text):
    return subprocess.check_output(["cast", "keccak", text]).decode().strip()


def selector(sig):
    return subprocess.check_output(["cast", "sig", sig]).decode().strip()


def call(to, data):
    for _ in range(5):
        r = rpc(STATE_RPC, "eth_call", [{"to": to, "data": data}, "latest"])
        if "result" in r:
            return r["result"]
    raise SystemExit("FAIL: eth_call failed for %s: %s" % (to, r))


pad = lambda a: "0x" + "0" * 24 + a[2:].lower()
SIGS = {
    "request": keccak("WithdrawalRequested(address,address[],uint256[],address,uint256)"),
    "cancel": keccak("WithdrawalCancelled(address,address[],uint256[],address)"),
    "process": keccak("WithdrawalProcessed(address,address[],uint256[],address)"),
}
KIND = {v: k for k, v in SIGS.items()}
recips = [pad(a) for a, _ in MODULES.values()]
latest = int(rpc(STATE_RPC, "eth_blockNumber", [])["result"], 16)


def logs(lo, hi):
    r = rpc(LOGS_RPC, "eth_getLogs", [{"fromBlock": hex(lo), "toBlock": hex(hi), "address": EMITTER,
                                      "topics": [list(SIGS.values()), None, recips]}])
    if "error" in r:
        if hi > lo:  # range too large or too many results: split
            mid = (lo + hi) // 2
            return logs(lo, mid) + logs(mid + 1, hi)
        raise SystemExit("FAIL: eth_getLogs: %s" % r["error"])
    return r["result"]


all_logs, b = [], FROM_BLOCK
while b <= latest:
    e = min(b + 399_999, latest)
    all_logs += logs(b, e)
    b = e + 1

by_pair, counts = {}, {}
addr_name = {a.lower(): n for n, (a, _) in MODULES.items()}
for l in all_logs:
    safe, rec = "0x" + l["topics"][1][-40:], "0x" + l["topics"][2][-40:]
    by_pair.setdefault((safe, rec), []).append((int(l["blockNumber"], 16), int(l["logIndex"], 16), KIND[l["topics"][0]]))
    counts.setdefault(rec, {"request": 0, "cancel": 0, "process": 0})[KIND[l["topics"][0]]] += 1

suspects = [(s, r) for (s, r), ev in by_pair.items() if sorted(ev)[-1][2] == "request"]
print("Scanned CashEventEmitter %s blocks %d..%d: %d logs, %d (safe, module) pairs, %d with a request as latest event"
      % (EMITTER, FROM_BLOCK, latest, len(all_logs), len(by_pair), len(suspects)))

SEL_PENDING = selector("getPendingBridge(address)")
SEL_DATA = selector("getData(address)")
pending = {}  # module -> [(safe, why)]
for safe, rec in suspects:
    arg = safe[2:].rjust(64, "0")
    why = []
    name = addr_name[rec]
    if MODULES[name][1]:
        out = call(MODULES[name][0], SEL_PENDING + arg)[2:]
        words = [out[i:i + 64] for i in range(0, len(out), 64)]
        if int(words[2], 16) != 0:
            why.append("getPendingBridge amount=%d dest=%s" % (int(words[2], 16), "0x" + words[3][-40:]))
    data = call(CASH_MODULE, SEL_DATA + arg).lower()
    if rec[2:] in data:
        why.append("CashModule.getData pendingWithdrawalRequest.recipient is the module")
    if why:
        pending.setdefault(name, []).append((safe, "; ".join(why)))

total = 0
print()
print("%-40s %9s %9s %9s %8s" % ("module", "requested", "processed", "cancelled", "PENDING"))
for name, (addr, _) in MODULES.items():
    c = counts.get(addr.lower(), {"request": 0, "cancel": 0, "process": 0})
    n = len(pending.get(name, []))
    total += n
    print("%-40s %9d %9d %9d %8d   %s" % (name, c["request"], c["process"], c["cancel"], n, addr))
for name, items in pending.items():
    for safe, why in items:
        print("  PENDING %s on %s: %s" % (name, safe, why))
print()
print("suspects cleared by live state (event ordering was stale, nothing pending): %d" % (len(suspects) - sum(len(v) for v in pending.values())))
print("PENDING_COUNT=%d" % total)
sys.exit(1 if total else 0)
PY
