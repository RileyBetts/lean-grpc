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
  dataBuf : ByteArray
  endHeaders : Bool
  endStreamRemote : Bool
  endStreamLocal : Bool
  deriving Inhabited

namespace Stream

def create (id : UInt32) (initWindow : UInt32) : Stream :=
  { id, state := .idle
    sendWindow := initWindow.toNat
    recvWindow := initWindow.toNat
    headersBuf := ByteArray.empty
    dataBuf := ByteArray.empty
    endHeaders := false
    endStreamRemote := false
    endStreamLocal := false }

def isClosed (s : Stream) : Bool := s.state == .closed

end Stream
end H2
