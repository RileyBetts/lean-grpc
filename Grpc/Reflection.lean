/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Server
import Grpc.Status
import Proto.Wire

namespace Grpc.Reflection

/-- Minimal server reflection: list services encoded as length-delimited strings in field 1. -/
def register (s : Server) (services : Array String) : Server :=
  Server.register s "grpc.reflection.v1alpha.ServerReflection" "ServerReflectionInfo" fun _ => do
    let mut acc := ByteArray.empty
    for name in services do
      acc := Proto.Wire.encodeString acc 1 name
    return (acc, Status.ok)

end Grpc.Reflection
