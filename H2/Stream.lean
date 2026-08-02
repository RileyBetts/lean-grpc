/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
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
  /-- Outbound body bytes waiting for flow-control window. -/
  pendingSend : ByteArray
  /-- Trailers to send after `pendingSend` drains (empty = none). -/
  pendingTrailers : Array Hpack.HeaderField
  /-- When true, END_STREAM after pending send drains (no trailers). -/
  pendingEndStream : Bool
  endHeaders : Bool
  endTrailers : Bool
  endStreamRemote : Bool
  endStreamLocal : Bool
  /-- True once the first header block has been completed (END_HEADERS). -/
  gotHeaders : Bool
  /-- True once we have sent response HEADERS on this stream. -/
  responseHeadersSent : Bool
  /-- True once the app handler returned `finished := true` (no further invokes). -/
  handlerFinished : Bool
  /-- Bytes of dataBuf already consumed by incremental streaming handlers. -/
  dataConsumed : Nat
  /-- Declared content-length from request headers, if any. -/
  contentLength : Option Nat
  /-- Decoded headers (set when END_HEADERS completes). -/
  requestHeaders : Array Hpack.HeaderField
  /-- Decoded trailers (set when trailer END_HEADERS completes). -/
  decodedTrailers : Array Hpack.HeaderField
  /-- Peer RST_STREAM error code when the stream was reset (`none` = not reset). -/
  rstErrorCode : Option UInt32 := none
  deriving Inhabited

namespace Stream

/-- `sendInit` = peer INITIAL_WINDOW_SIZE; `recvInit` = our INITIAL_WINDOW_SIZE. -/
def create (id : UInt32) (sendInit recvInit : UInt32) : Stream :=
  { id, state := .idle
    sendWindow := sendInit.toNat
    recvWindow := recvInit.toNat
    headersBuf := ByteArray.empty
    trailersBuf := ByteArray.empty
    dataBuf := ByteArray.empty
    pendingSend := ByteArray.empty
    pendingTrailers := #[]
    pendingEndStream := false
    endHeaders := false
    endTrailers := false
    endStreamRemote := false
    endStreamLocal := false
    gotHeaders := false
    responseHeadersSent := false
    handlerFinished := false
    dataConsumed := 0
    contentLength := none
    requestHeaders := #[]
    decodedTrailers := #[]
    rstErrorCode := none }

def isClosed (s : Stream) : Bool := s.state == .closed

/-- Response (or request) is complete when remote END_STREAM seen and header block(s) finished. -/
def responseComplete (s : Stream) : Bool :=
  s.endStreamRemote && s.endHeaders && (s.endTrailers || s.trailersBuf.isEmpty && s.gotHeaders)

end Stream
end H2
