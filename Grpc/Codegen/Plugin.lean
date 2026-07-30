/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Codegen.Emit

/-- `protoc-gen-lean4-grpc` plugin entry (reads CodeGeneratorRequest from stdin).
    For Phase 4 we accept a simplified path: env LEAN_GRPC_PROTO points to a .proto
    file and we emit stubs to stdout / LEAN_GRPC_OUT. Full protobuf plugin framing
    can wrap this emitter. -/
def main (args : List String) : IO UInt32 := do
  let protoPath ←
    match args with
    | p :: _ => pure p
    | [] =>
      match ← IO.getEnv "LEAN_GRPC_PROTO" with
      | some p => pure p
      | none =>
        IO.eprintln "usage: protoc-gen-lean4-grpc <file.proto>  (or set LEAN_GRPC_PROTO)"
        return 2
  let outDir := (← IO.getEnv "LEAN_GRPC_OUT").getD "."
  let text ← IO.FS.readFile protoPath
  let lean ← Grpc.Codegen.emitFromProto text
  let outPath := System.FilePath.join outDir "Generated.lean"
  IO.FS.writeFile outPath lean
  IO.println s!"wrote {outPath}"
  return 0
