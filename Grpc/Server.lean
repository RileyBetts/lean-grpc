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
  deriving Inhabited

namespace Server

def empty : Server := ⟨#[]⟩

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

def serveH2c (s : Server) (cfg : H2.ServerConfig := {}) : IO Unit := do
  let handler : H2.StreamHandler := fun _streamId headers data => do
    let mut path := ""
    for h in headers do
      let (n, v) := headerAscii h
      if n == ":path" then path := v
    match findHandler s path with
    | none =>
      let trailers := Metadata.http200 ++ Metadata.statusHeaders (.unimplemented s!"unknown {path}")
      return (trailers, ByteArray.empty, true)
    | some h =>
      let payloads ← IO.ofExcept (Message.decodeAll (Bytes.Slice.ofByteArray data))
      let req := payloads.getD 0 ByteArray.empty
      let (resp, st) ← h req
      let body := if resp.isEmpty && st.code == .ok then ByteArray.empty else Message.encode resp
      -- Send headers (:status/content-type) + data + trailers would need two HEADERS frames.
      -- Our H2 server helper sends one HEADERS + optional DATA. Put grpc-status in HEADERS
      -- for trailers-only / combined response (acceptable for unary OK/error).
      let hdrs := Metadata.http200 ++ Metadata.statusHeaders st
      return (hdrs, body, true)
  H2.Server.listen cfg handler

end Server
end Grpc
