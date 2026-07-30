#!/usr/bin/env bash
# Alias: Lean server ← Go client (same as run-go-to-lean.sh)
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/run-go-to-lean.sh"
