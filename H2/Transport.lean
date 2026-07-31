/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std.Async.TCP

open Std.Async

namespace H2

/-- Byte pipe under HTTP/2 (plain TCP or TLS). -/
structure ByteTransport where
  send : ByteArray → IO Unit
  recv? : Nat → IO (Option ByteArray)
  close : IO Unit := pure ()

/-- Wrap a connected `Std.Async` TCP client. -/
def tcpTransport (sock : TCP.Socket.Client) : ByteTransport where
  send := fun b => (sock.send b).block
  recv? := fun n => (sock.recv? n.toUInt64).block
  close := pure ()

end H2
