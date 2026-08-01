/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Server
import Grpc.Status
import Proto.Wire

namespace Grpc.Health

inductive ServingStatus where
  | unknown | serving | notServing | serviceUnknown
  deriving BEq, Inhabited

def ServingStatus.toUInt32 : ServingStatus → UInt32
  | .unknown => 0 | .serving => 1 | .notServing => 2 | .serviceUnknown => 3

/-- Register standard `grpc.health.v1.Health/Check`. -/
def register (s : Server) (status : ServingStatus := .serving) : Server :=
  Server.register s "grpc.health.v1.Health" "Check" fun _req => do
    let body := Proto.Wire.encodeUInt32 ByteArray.empty 1 status.toUInt32
    return (body, Status.ok)

/-- Register `grpc.health.v1.Health/Watch` (server-streaming `HealthCheckResponse`).
    `statusRef` lets the server flip serving status at runtime (e.g. during drain) and have
    both `Check` and `Watch` observe the change. This minimal server-streaming subset emits
    the current status once per call rather than keeping the stream open across future
    transitions — enough to exercise the RPC shape end to end. -/
def registerWatch (s : Server) (statusRef : IO.Ref ServingStatus) : Server :=
  Server.registerServerStream s "grpc.health.v1.Health" "Watch" fun _req => do
    let status ← statusRef.get
    let body := Proto.Wire.encodeUInt32 ByteArray.empty 1 status.toUInt32
    return (#[body], Status.ok)

/-- Register `Check` + `Watch` sharing one live status ref. -/
def registerWithWatch (s : Server) (statusRef : IO.Ref ServingStatus) : Server :=
  let s := Server.register s "grpc.health.v1.Health" "Check" fun _req => do
    let status ← statusRef.get
    return (Proto.Wire.encodeUInt32 ByteArray.empty 1 status.toUInt32, Status.ok)
  registerWatch s statusRef

end Grpc.Health
