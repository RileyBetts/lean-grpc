/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc

/-- Live Google ADC check (see `scripts/run-adc-live.sh`): unlike `Tests/AdcSmoke.lean`,
    this talks to the real GCE metadata server or the real
    `https://oauth2.googleapis.com/token` endpoint — no `LEAN_GRPC_*` mock overrides — so
    it only succeeds with real credentials (a real `GOOGLE_APPLICATION_CREDENTIALS` service
    account key, or actually running on a GCE instance). Prints a redacted token prefix and
    exits 0 on success. -/
def main (args : List String) : IO Unit := do
  Grpc.Adc.clearCache
  let tok ← Grpc.Adc.accessToken
  if tok.isEmpty then throw (IO.userError "adc live: empty access token")
  if args == ["--full"] then
    -- Only for manual live verification (e.g. piping into a tokeninfo curl call);
    -- never printed by default so tokens don't end up in ordinary log output.
    IO.println tok
  else
    let preview := (tok.take 12).toString
    IO.println s!"adcLive OK token={preview}... len={tok.length}"
