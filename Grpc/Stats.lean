/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
namespace Grpc.Stats

/-- Minimal client/server call counters (a small subset of the gRPC OpenCensus/OpenTelemetry
    stats surface: calls started/completed/failed + bytes moved). -/
structure Counters where
  callsStarted : Nat := 0
  callsCompleted : Nat := 0
  callsFailed : Nat := 0
  bytesSent : Nat := 0
  bytesReceived : Nat := 0
  deriving Inhabited

abbrev Registry := IO.Ref Counters

def newRegistry : IO Registry := IO.mkRef {}

def recordStart (r : Registry) : IO Unit :=
  r.modify fun c => { c with callsStarted := c.callsStarted + 1 }

def recordSuccess (r : Registry) (sentBytes recvBytes : Nat := 0) : IO Unit :=
  r.modify fun c => { c with
    callsCompleted := c.callsCompleted + 1
    bytesSent := c.bytesSent + sentBytes
    bytesReceived := c.bytesReceived + recvBytes }

def recordFailure (r : Registry) : IO Unit :=
  r.modify fun c => { c with callsFailed := c.callsFailed + 1 }

def snapshot (r : Registry) : IO Counters := r.get

/-- Render as simple `metric_name value` lines (Prometheus/OTel-exposition-style; a real OTel
    exporter would additionally attach resource/unit metadata, but this is enough to feed one
    into a text-based collector or `stdout`). -/
def toLines (c : Counters) : Array String :=
  #[
    s!"grpc_calls_started_total {c.callsStarted}",
    s!"grpc_calls_completed_total {c.callsCompleted}",
    s!"grpc_calls_failed_total {c.callsFailed}",
    s!"grpc_sent_bytes_total {c.bytesSent}",
    s!"grpc_received_bytes_total {c.bytesReceived}"
  ]

/-- Print current counters to stdout. -/
def exportStdout (r : Registry) : IO Unit := do
  let c ← r.get
  for line in toLines c do
    IO.println line

/-- Pluggable exporter shim: swap `send` for a real OTLP HTTP/gRPC exporter. Defaults to
    stdout so the stats surface is exercisable without any external collector. -/
structure OtelExporter where
  send : Array String → IO Unit := fun lines => lines.forM IO.println

def OtelExporter.stdout : OtelExporter := {}

def OtelExporter.export (e : OtelExporter) (r : Registry) : IO Unit := do
  let c ← r.get
  e.send (toLines c)

end Grpc.Stats
