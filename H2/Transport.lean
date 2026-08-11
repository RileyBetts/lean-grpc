/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std.Async.TCP

open Std.Async

namespace H2

/-- Async byte pipe under HTTP/2 (plain TCP). Prefer this over `ByteTransport`
    when composing under `Std.Async` so send/recv do not call `.block`. -/
structure AsyncByteTransport where
  send : ByteArray → Async Unit
  recv? : Nat → Async (Option ByteArray)
  close : Async Unit := pure ()

/-- Synchronous byte pipe (legacy / TLS FFI). Each op may block the caller. -/
structure ByteTransport where
  send : ByteArray → IO Unit
  recv? : Nat → IO (Option ByteArray)
  close : IO Unit := pure ()

/-- Wrap a connected `Std.Async` TCP client without `.block`. -/
def tcpTransportAsync (sock : TCP.Socket.Client) : AsyncByteTransport where
  send := fun b => sock.send b
  recv? := fun n => sock.recv? n.toUInt64
  close := pure ()

/-- Lift blocking `IO` send/recv into `Async` (still blocks the UV thread while
    the IO runs — used for OpenSSL FFI transports in v1.2.0). -/
def AsyncByteTransport.ofBlocking (t : ByteTransport) : AsyncByteTransport where
  send := fun b => liftM (t.send b)
  recv? := fun n => liftM (t.recv? n)
  close := liftM t.close

/-- Sync facade: each op `.block`s the underlying async transport. -/
def ByteTransport.ofAsync (t : AsyncByteTransport) : ByteTransport where
  send := fun b => (t.send b).block
  recv? := fun n => (t.recv? n).block
  close := t.close.block

/-- Wrap a connected `Std.Async` TCP client as a **blocking** `ByteTransport`
    (compatibility adapter; prefer `tcpTransportAsync` + `*Async` APIs). -/
def tcpTransport (sock : TCP.Socket.Client) : ByteTransport :=
  .ofAsync (tcpTransportAsync sock)

end H2
