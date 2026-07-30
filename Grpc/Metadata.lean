/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Hpack
import Grpc.Status

namespace Grpc

structure Metadata where
  entries : Array Hpack.HeaderField := #[]
  deriving Inhabited

namespace Metadata

def empty : Metadata := {}

def ascii (s : String) : ByteArray :=
  ByteArray.mk (s.toList.map (·.toNat.toUInt8)).toArray

def add (m : Metadata) (name value : String) : Metadata :=
  { m with entries := m.entries.push ⟨ascii name, ascii value⟩ }

def get? (m : Metadata) (name : String) : Option String :=
  let n := ascii name
  Id.run do
    for e in m.entries do
      if e.name == n then
        return some (String.ofList (e.value.toList.map (fun b => Char.ofNat b.toNat)))
    return none

def contentTypeGrpc : Hpack.HeaderField :=
  ⟨ascii "content-type", ascii "application/grpc+proto"⟩

def path (service method : String) : Hpack.HeaderField :=
  ⟨ascii ":path", ascii s!"/{service}/{method}"⟩

def methodPost : Hpack.HeaderField := ⟨ascii ":method", ascii "POST"⟩
def schemeHttp : Hpack.HeaderField := ⟨ascii ":scheme", ascii "http"⟩
def teTrailers : Hpack.HeaderField := ⟨ascii "te", ascii "trailers"⟩

def statusHeaders (st : Status) : Array Hpack.HeaderField :=
  let base := #[⟨ascii "grpc-status", ascii (toString st.code.toUInt32)⟩]
  if st.message.isEmpty then base
  else base.push ⟨ascii "grpc-message", ascii st.message⟩

def http200 : Array Hpack.HeaderField :=
  #[⟨ascii ":status", ascii "200"⟩, contentTypeGrpc]

end Metadata
end Grpc
