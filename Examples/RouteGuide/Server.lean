/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Proto
import H2
import Bytes.Slice
import Bytes.Pool

/-- Demo RouteGuide server: GetFeature + ListFeatures + RecordRoute + RouteChat. -/
def main : IO Unit := do
  let port := ((← IO.getEnv "GRPC_PORT").getD "50052").toNat?.getD 50052 |>.toUInt16
  let handler : H2.StreamHandler := fun _ headers data endStream headersSent => do
    let path :=
      Id.run do
        for h in headers do
          let n := String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat))
          let v := String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat))
          if n == ":path" then return v
        return ""
    let okTrail := Grpc.Metadata.statusHeaders .ok
    let hdrs := Grpc.Metadata.http200
    match path with
    | "/routeguide.RouteGuide/GetFeature" =>
      if !endStream then return { finished := false }
      -- Echo a named feature; request body ignored for the demo.
      let reply := Proto.Wire.encodeString ByteArray.empty 1 "Lean Peak"
      return { headers := hdrs, body := Grpc.Message.encodeId reply, trailers := okTrail, finished := true }
    | "/routeguide.RouteGuide/ListFeatures" =>
      if !endStream then return { finished := false }
      let mut out := ByteArray.empty
      for name in ["Alpha", "Beta", "Gamma"] do
        let feat := Proto.Wire.encodeString ByteArray.empty 1 name
        out := Bytes.Pool.pushBytes out (Grpc.Message.encodeId feat)
      return { headers := hdrs, body := out, trailers := okTrail, finished := true }
    | "/routeguide.RouteGuide/RecordRoute" =>
      if !endStream then return { finished := false }
      let msgs ← IO.ofExcept (Grpc.Message.decodeAll (Bytes.Slice.ofByteArray data))
      let summary := Proto.Wire.encodeUInt32 ByteArray.empty 1 msgs.size.toUInt32
      return { headers := hdrs, body := Grpc.Message.encodeId summary, trailers := okTrail, finished := true }
    | "/routeguide.RouteGuide/RouteChat" =>
      let (msgs, _) ← IO.ofExcept (Grpc.Stream.decodeAvailable data)
      if msgs.isEmpty && !endStream then return { finished := false }
      let mut out := ByteArray.empty
      for m in msgs do
        out := Bytes.Pool.pushBytes out (Grpc.Message.encodeId m) -- echo notes
      if endStream then
        return {
          headers := if headersSent then #[] else hdrs
          body := out
          trailers := okTrail
          finished := true
        }
      else
        return {
          headers := if headersSent then #[] else hdrs
          body := out
          finished := false
        }
    | _ =>
      if !endStream then return { finished := false }
      return {
        headers := hdrs
        trailers := Grpc.Metadata.statusHeaders (.unimplemented path)
        finished := true
      }
  H2.Server.listen { host := "127.0.0.1", port } handler
