#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Hard-gate wrapper for the three narrative stress demos + framing matrix.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
chmod +x \
  scripts/run-vault-gauntlet.sh \
  scripts/run-mirror-forge.sh \
  scripts/run-signal-weave.sh \
  scripts/run-framing-matrix.sh \
  scripts/build_native.sh

echo "== VaultGauntlet (Lean↔Lean) =="
./scripts/run-vault-gauntlet.sh

echo "== MirrorForge (Lean↔Lean dual-backend) =="
./scripts/run-mirror-forge.sh

echo "== SignalWeave (Go→Lean) =="
./scripts/run-signal-weave.sh

echo "== Framing matrix (Lean↔Lean + Go→Lean) =="
./scripts/run-framing-matrix.sh

echo "ALL STRESS / FRAMING GATES PASSED"
