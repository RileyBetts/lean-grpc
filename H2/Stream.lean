/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Hpack

namespace H2

inductive StreamState where
  | idle
  | open
  | halfClosedLocal
  | halfClosedRemote
  | closed
  | reservedLocal
  | reservedRemote
  deriving BEq, Inhabited

structure Stream where
  id : UInt32
  state : StreamState
  sendWindow : Int
  recvWindow : Int
  headersBuf : ByteArray
  trailersBuf : ByteArray
  dataBuf : ByteArray
  endHeaders : Bool
  endTrailers : Bool
  endStreamRemote : Bool
  endStreamLocal : Bool
  /-- True once the first header block has been completed (END_HEADERS). -/
  gotHeaders : Bool
  /-- True once we have sent response HEADERS on this stream. -/
  responseHeadersSent : Bool
  /-- Bytes of dataBuf already consumed by incremental streaming handlers. -/
  dataConsumed : Nat
  deriving Inhabited

namespace Stream

def create (id : UInt32) (initWindow : UInt32) : Stream :=
  { id, state := .idle
    sendWindow := initWindow.toNat
    recvWindow := initWindow.toNat
    headersBuf := ByteArray.empty
    trailersBuf := ByteArray.empty
    dataBuf := ByteArray.empty
    endHeaders := false
    endTrailers := false
    endStreamRemote := false
    endStreamLocal := false
    gotHeaders := false
    responseHeadersSent := false
    dataConsumed := 0 }

def isClosed (s : Stream) : Bool := s.state == .closed

/-- Response (or request) is complete when remote END_STREAM seen and header block(s) finished. -/
def responseComplete (s : Stream) : Bool :=
  s.endStreamRemote && s.endHeaders && (s.endTrailers || s.trailersBuf.isEmpty && s.gotHeaders)

end Stream
end H2
