/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
namespace H2

def clientPreface : ByteArray :=
  ByteArray.mk ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".toList.map (·.toNat.toUInt8)).toArray

end H2
