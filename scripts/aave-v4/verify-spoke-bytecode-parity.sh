#!/usr/bin/env bash
# Proves that this repo's audited EtherFiSpokeInstance compiles to the EXACT bytecode the
# aave-v4 whitelabel launch branch deploys.
#
# solc assigns some internal IDs from source-path sort order, so building the contract inside
# cash-v3's own layout differs from the aave build by a few permuted bytes. This script instead
# reconstructs the aave layout from THIS REPO'S pinned sources only — the lib/aave-v4 submodule
# tree plus src/aave-v4/EtherFiSpokeInstance.sol (import rewritten to the aave-rooted path) —
# and compiles with the aave launch branch's exact settings (solc 0.8.28, cancun, via-ir,
# 750 runs for the spoke unit, bytecode_hash none, LiquidationLogic linked at its deterministic
# CREATE2 address).
#
# Usage:
#   scripts/aave-v4/verify-spoke-bytecode-parity.sh                       # print artifact hashes
#   AAVE_ARTIFACT=<path/to/EtherFiSpokeInstance.json> scripts/aave-v4/verify-spoke-bytecode-parity.sh
#                                                                         # additionally byte-compare
set -euo pipefail
cd "$(dirname "$0")/../.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/src/etherfi"
cp -r lib/aave-v4/src/* "$WORK/src/"
sed 's|import { SpokeInstance } from "aave-v4/spoke/instances/SpokeInstance.sol";|import {SpokeInstance} from '"'"'src/spoke/instances/SpokeInstance.sol'"'"';|' \
  src/aave-v4/EtherFiSpokeInstance.sol > "$WORK/src/etherfi/EtherFiSpokeInstance.sol"

cat > "$WORK/foundry.toml" <<'TOML'
[profile.default]
src = 'src'
solc_version = "0.8.28"
evm_version = "cancun"
optimizer = true
optimizer_runs = 44444444
bytecode_hash = "none"
libraries = ["src/spoke/libraries/LiquidationLogic.sol:LiquidationLogic:0x818E84198224535FAeaEc1b583d3Ff6b812A5AF3"]
additional_compiler_profiles = [
  { name = "spoke", optimizer = true, via_ir = true, optimizer_runs = 750 },
]
compilation_restrictions = [
  { paths = "src/spoke/instances/SpokeInstance.sol", via_ir = true, optimizer_runs = 750 },
  { paths = "src/etherfi/EtherFiSpokeInstance.sol", via_ir = true, optimizer_runs = 750 },
]
TOML

(cd "$WORK" && forge build src/etherfi/EtherFiSpokeInstance.sol > /dev/null)

ART="$WORK/out/EtherFiSpokeInstance.sol/EtherFiSpokeInstance.json"
CREATION=$(jq -r '.bytecode.object' "$ART")
RUNTIME=$(jq -r '.deployedBytecode.object' "$ART")
echo "creation bytecode keccak256: $(cast keccak "$CREATION")"
echo "runtime  bytecode keccak256: $(cast keccak "$RUNTIME")"

if [[ -n "${AAVE_ARTIFACT:-}" ]]; then
  A_CREATION=$(jq -r '.bytecode.object' "$AAVE_ARTIFACT")
  A_RUNTIME=$(jq -r '.deployedBytecode.object' "$AAVE_ARTIFACT")
  [[ "$CREATION" == "$A_CREATION" ]] || { echo "MISMATCH: creation bytecode differs"; exit 1; }
  [[ "$RUNTIME" == "$A_RUNTIME" ]] || { echo "MISMATCH: runtime bytecode differs"; exit 1; }
  echo "MATCH: byte-identical to $AAVE_ARTIFACT"
fi
