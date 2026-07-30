/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Server
import Grpc.Status
import Proto.Wire

namespace Grpc.Channelz

structure Counters where
  callsStarted : Nat := 0
  callsSucceeded : Nat := 0
  callsFailed : Nat := 0
  deriving Inhabited

/-- In-process counters (also exposed via a tiny GetTopChannels-like unary). -/
def register (s : Server) (counters : IO.Ref Counters) : Server :=
  Server.register s "grpc.channelz.v1.Channelz" "GetTopChannels" fun _ => do
    let c ← counters.get
    let mut acc := ByteArray.empty
    acc := Proto.Wire.encodeUInt32 acc 1 c.callsStarted.toUInt32
    acc := Proto.Wire.encodeUInt32 acc 2 c.callsSucceeded.toUInt32
    acc := Proto.Wire.encodeUInt32 acc 3 c.callsFailed.toUInt32
    return (acc, Status.ok)

def recordSuccess (r : IO.Ref Counters) : IO Unit := do
  let c ← r.get
  r.set { c with callsStarted := c.callsStarted + 1, callsSucceeded := c.callsSucceeded + 1 }

def recordFailure (r : IO.Ref Counters) : IO Unit := do
  let c ← r.get
  r.set { c with callsStarted := c.callsStarted + 1, callsFailed := c.callsFailed + 1 }

end Grpc.Channelz
