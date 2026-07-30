/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Bytes.BE
import Bytes.Pool

namespace Grpc
namespace Message

/-- Length-prefixed gRPC message: Compressed-Flag (1) + Length (4 BE) + Message. -/
def encode (payload : ByteArray) (compressed : Bool := false) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    out := out.push (if compressed then 1 else 0)
    out := Bytes.Pool.pushBytes out (Bytes.BE.u32Bytes payload.size.toUInt32)
    out := Bytes.Pool.pushBytes out payload
    return out

/-- Decode one message; returns payload and remaining bytes. -/
def decodeOne (buf : Bytes.Slice) : Except String (ByteArray × Bytes.Slice) := do
  if buf.size < 5 then throw "short grpc frame"
  let compressed := buf.get! 0 != 0
  if compressed then throw "compression not supported (identity only)"
  let len ← Bytes.BE.readU32 buf 1 |>.elim (throw "len") pure
  let n := len.toNat
  if buf.size < 5 + n then throw "incomplete grpc message"
  let payload := (buf.sub 5 n).toByteArray
  return (payload, buf.sub (5 + n) (buf.size - 5 - n))

/-- Decode all messages in a buffer. -/
def decodeAll (buf : Bytes.Slice) : Except String (Array ByteArray) := do
  let mut s := buf
  let mut out : Array ByteArray := #[]
  while !s.isEmpty do
    let (p, rest) ← decodeOne s
    out := out.push p
    s := rest
  return out

end Message
end Grpc
