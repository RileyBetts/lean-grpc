/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
namespace Bytes

/-- Simple recycle pool for write buffers (per-connection use). -/
structure Pool where
  free : Array ByteArray
  deriving Inhabited

namespace Pool

def empty : Pool := ⟨#[]⟩

def acquire (p : Pool) (minSize : Nat := 0) : Pool × ByteArray :=
  match p.free.findIdx? (fun b => b.size ≥ minSize ∨ minSize == 0) with
  | some i =>
    let b := p.free[i]!
    let free' := p.free.eraseIdx! i
    (⟨free'⟩, b)
  | none =>
    (p, ByteArray.empty)

def release (p : Pool) (b : ByteArray) : Pool :=
  if b.size == 0 then p
  else if p.free.size ≥ 32 then p  -- cap pool size
  else ⟨p.free.push b⟩

/-- Grow a buffer by pushing bytes (may allocate). -/
def pushBytes (acc : ByteArray) (bs : ByteArray) : ByteArray :=
  Id.run do
    let mut out := acc
    for i in [:bs.size] do
      out := out.push (bs.get! i)
    return out

end Pool
end Bytes
