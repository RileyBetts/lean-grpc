#!/usr/bin/env bash
# Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
# Live Google Application Default Credentials (ADC) check — MANUAL / NIGHTLY ONLY.
#
# Unlike `scripts/run-adc-smoke.sh` (mocked metadata/token server, safe for regular CI),
# this script talks to real Google endpoints:
#   - a real GCE instance metadata server (only reachable when actually running on GCE), or
#   - the real `https://oauth2.googleapis.com/token` endpoint, using a real service-account
#     key referenced by `GOOGLE_APPLICATION_CREDENTIALS`.
#
# It is intentionally NOT wired into the default `lake build`/interop CI: it requires live
# credentials and network egress to Google, which regular CI runners/sandboxes don't have.
# Run it by hand, or from a nightly job that has real credentials configured, e.g.:
#
#   GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json ./scripts/run-adc-live.sh
#
# or, on an actual GCE VM with a workload identity / attached service account:
#
#   ./scripts/run-adc-live.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Make sure none of the CI mock overrides leak in from the caller's environment —
# this script only makes sense against real Google endpoints.
unset LEAN_GRPC_GCE_METADATA LEAN_GRPC_TOKEN_INSECURE LEAN_GRPC_TOKEN_HOST LEAN_GRPC_TOKEN_PATH

if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
  echo "NOTE: GOOGLE_APPLICATION_CREDENTIALS not set; this will only work when actually" >&2
  echo "running on a GCE instance with an attached service account." >&2
fi

lake build adcLive

echo "Fetching a live ADC token..."
./.lake/build/bin/adcLive

# Best-effort live verification against Google's tokeninfo endpoint, confirming the
# token is real and currently valid (skipped if curl is unavailable). `adcLive --full`
# prints the unredacted token — only ever used here, piped straight into curl, never
# logged.
if command -v curl >/dev/null 2>&1; then
  echo "Verifying token against https://oauth2.googleapis.com/tokeninfo ..."
  full_token="$(./.lake/build/bin/adcLive --full)"
  curl -sf "https://oauth2.googleapis.com/tokeninfo?access_token=${full_token}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("tokeninfo scope:", d.get("scope", d))'
else
  echo "curl not found; skipping live tokeninfo verification."
fi

echo "run-adc-live OK"
