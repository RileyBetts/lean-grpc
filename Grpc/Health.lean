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

end Grpc.Health
