/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import H2
import Hpack
import Proto
import Grpc.Status
import Grpc.Message
import Grpc.Metadata

namespace Grpc

/-- Unary handler: request bytes → response bytes + status. -/
abbrev UnaryHandler := ByteArray → IO (ByteArray × Status)

structure ServiceMethod where
  service : String
  method : String
  handler : UnaryHandler

structure Server where
  methods : Array ServiceMethod
  maxMsgSize : Nat := 4 * 1024 * 1024
  deriving Inhabited

namespace Server

def empty : Server := ⟨#[], 4 * 1024 * 1024⟩

def register (s : Server) (service method : String) (h : UnaryHandler) : Server :=
  { s with methods := s.methods.push ⟨service, method, h⟩ }

private def findHandler (s : Server) (path : String) : Option UnaryHandler :=
  Id.run do
    for m in s.methods do
      let p := s!"/{m.service}/{m.method}"
      if p == path then return some m.handler
    return none

private def headerAscii (h : Hpack.HeaderField) : String × String :=
  (String.ofList (h.name.toList.map (fun b => Char.ofNat b.toNat)),
   String.ofList (h.value.toList.map (fun b => Char.ofNat b.toNat)))

/-- Parse gRPC timeout like `10S`, `100m`, `5M`, `1H`, `100u`, `100n` into milliseconds. -/
def parseTimeoutMs (t : String) : Option Nat :=
  if t.isEmpty then none
  else
    let chars := t.toList
    match chars.reverse with
    | [] => none
    | unit :: restRev =>
      let numStr := String.ofList restRev.reverse
      match numStr.toNat? with
      | none => none
      | some n =>
        match unit with
        | 'H' => some (n * 3600 * 1000)
        | 'M' => some (n * 60 * 1000)
        | 'S' => some (n * 1000)
        | 'm' => some n
        | 'u' => some (if n == 0 then 0 else max 1 (n / 1000))
        | 'n' => some 0
        | _ => none

def serveH2c (s : Server) (cfg : H2.ServerConfig := {}) : IO Unit := do
  let handler : H2.StreamHandler := fun _streamId headers data endStream headersSent => do
    if headersSent && !endStream then
      return { finished := false }
    if !endStream then
      -- Unary waits for client half-close.
      return { finished := false }
    let mut path := ""
    let mut contentType := ""
    let mut timeout := ""
    for h in headers do
      let (n, v) := headerAscii h
      if n == ":path" then path := v
      if n == "content-type" then contentType := v
      if n == "grpc-timeout" then timeout := v
    if !(contentType.isEmpty || "application/grpc".isPrefixOf contentType) then
      return {
        headers := Metadata.http200
        trailers := Metadata.statusHeaders (.internal "bad content-type")
        finished := true
      }
    if let some ms := parseTimeoutMs timeout then
      if ms == 0 then
        return {
          headers := Metadata.http200
          trailers := Metadata.statusHeaders (.deadlineExceeded)
          finished := true
        }
    match findHandler s path with
    | none =>
      return {
        headers := Metadata.http200
        trailers := Metadata.statusHeaders (.unimplemented s!"unknown {path}")
        finished := true
      }
    | some h =>
      if data.size > s.maxMsgSize + 5 then
        return {
          headers := Metadata.http200
          trailers := Metadata.statusHeaders (.resourceExhausted "message too large")
          finished := true
        }
      let payloads ←
        match Message.decodeAll (Bytes.Slice.ofByteArray data) with
        | .ok ps => pure ps
        | .error e =>
          return {
            headers := Metadata.http200
            trailers := Metadata.statusHeaders (.internal e)
            finished := true
          }
      let req := payloads.getD 0 ByteArray.empty
      if req.size > s.maxMsgSize then
        return {
          headers := Metadata.http200
          trailers := Metadata.statusHeaders (.resourceExhausted "message too large")
          finished := true
        }
      let (resp, st) ← h req
      let body := if st.code != .ok && resp.isEmpty then ByteArray.empty
                  else Message.encodeId resp
      return {
        headers := Metadata.http200
        body
        trailers := Metadata.statusHeaders st
        finished := true
      }
  H2.Server.listen cfg handler

end Server
end Grpc
