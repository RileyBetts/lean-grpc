/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Server
import Grpc.Status
import Proto.Wire

namespace Grpc.Channelz

structure Counters where
  callsStarted : Nat := 0
  callsSucceeded : Nat := 0
  callsFailed : Nat := 0
  deriving Inhabited

/-- `ChannelRef`/`ServerRef` share the same `{ id = 1; name = 2 }` shape. -/
private def encodeRef (id : UInt32) (name : String) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    acc := Proto.Wire.encodeUInt32 acc 1 id
    if !name.isEmpty then acc := Proto.Wire.encodeString acc 2 name
    return acc

/-- `channelz.v1.ChannelConnectivityState.READY`. -/
private def readyState : UInt32 := 2

/-- `ChannelData { state = 1; calls_started = 6; calls_succeeded = 7; calls_failed = 8 }`. -/
private def encodeChannelData (c : Counters) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    acc := Proto.Wire.encodeUInt32 acc 1 readyState
    acc := Proto.Wire.encodeUInt32 acc 6 c.callsStarted.toUInt32
    acc := Proto.Wire.encodeUInt32 acc 7 c.callsSucceeded.toUInt32
    acc := Proto.Wire.encodeUInt32 acc 8 c.callsFailed.toUInt32
    return acc

/-- `Channel { ref = 1; data = 2 }`. -/
private def encodeChannel (id : UInt32) (name : String) (c : Counters) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    acc := Proto.Wire.encodeMessage acc 1 (encodeRef id name)
    acc := Proto.Wire.encodeMessage acc 2 (encodeChannelData c)
    return acc

/-- `GetTopChannelsResponse { channel = 1 (repeated); end = 2 }`. -/
private def encodeGetTopChannelsResponse (id : UInt32) (name : String) (c : Counters) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    acc := Proto.Wire.encodeMessage acc 1 (encodeChannel id name c)
    acc := Proto.Wire.encodeBool acc 2 true
    return acc

/-- `ServerData { calls_started = 1; calls_succeeded = 2; calls_failed = 3 }`. -/
private def encodeServerData (c : Counters) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    acc := Proto.Wire.encodeUInt32 acc 1 c.callsStarted.toUInt32
    acc := Proto.Wire.encodeUInt32 acc 2 c.callsSucceeded.toUInt32
    acc := Proto.Wire.encodeUInt32 acc 3 c.callsFailed.toUInt32
    return acc

/-- `Server { ref = 1; data = 2 }`. -/
private def encodeServer (id : UInt32) (name : String) (c : Counters) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    acc := Proto.Wire.encodeMessage acc 1 (encodeRef id name)
    acc := Proto.Wire.encodeMessage acc 2 (encodeServerData c)
    return acc

/-- `GetServersResponse { server = 1 (repeated); end = 2 }`. -/
private def encodeGetServersResponse (id : UInt32) (name : String) (c : Counters) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    acc := Proto.Wire.encodeMessage acc 1 (encodeServer id name c)
    acc := Proto.Wire.encodeBool acc 2 true
    return acc

/-- Register `grpc.channelz.v1.Channelz/{GetTopChannels,GetServers}` backed by live
    in-process counters (single synthetic channel/server id, as this library serves one
    logical endpoint per process). -/
def register (s : Server) (counters : IO.Ref Counters) : Server :=
  let s := Server.register s "grpc.channelz.v1.Channelz" "GetTopChannels" fun _req => do
    let c ← counters.get
    return (encodeGetTopChannelsResponse 1 "lean-grpc-channel-1" c, Status.ok)
  Server.register s "grpc.channelz.v1.Channelz" "GetServers" fun _req => do
    let c ← counters.get
    return (encodeGetServersResponse 1 "lean-grpc-server-1" c, Status.ok)

/-- Client-side decode: pull the first channel's `ChannelData` counters out of a
    `GetTopChannelsResponse`. -/
def decodeGetTopChannelsCounters (b : ByteArray) : Except String Counters := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let chBytes ← (Proto.Wire.fieldBytes? fields 1).elim (throw "no channel") pure
  let chFields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray chBytes)
  let dataBytes ← (Proto.Wire.fieldBytes? chFields 2).elim (throw "no channel data") pure
  let dataFields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray dataBytes)
  return {
    callsStarted := ((Proto.Wire.fieldUInt32? dataFields 6).getD 0).toNat
    callsSucceeded := ((Proto.Wire.fieldUInt32? dataFields 7).getD 0).toNat
    callsFailed := ((Proto.Wire.fieldUInt32? dataFields 8).getD 0).toNat
  }

/-- Client-side decode: pull the first server's `ServerData` counters out of a
    `GetServersResponse`. -/
def decodeGetServersCounters (b : ByteArray) : Except String Counters := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let srvBytes ← (Proto.Wire.fieldBytes? fields 1).elim (throw "no server") pure
  let srvFields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray srvBytes)
  let dataBytes ← (Proto.Wire.fieldBytes? srvFields 2).elim (throw "no server data") pure
  let dataFields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray dataBytes)
  return {
    callsStarted := ((Proto.Wire.fieldUInt32? dataFields 1).getD 0).toNat
    callsSucceeded := ((Proto.Wire.fieldUInt32? dataFields 2).getD 0).toNat
    callsFailed := ((Proto.Wire.fieldUInt32? dataFields 3).getD 0).toNat
  }

def recordSuccess (r : IO.Ref Counters) : IO Unit := do
  let c ← r.get
  r.set { c with callsStarted := c.callsStarted + 1, callsSucceeded := c.callsSucceeded + 1 }

def recordFailure (r : IO.Ref Counters) : IO Unit := do
  let c ← r.get
  r.set { c with callsStarted := c.callsStarted + 1, callsFailed := c.callsFailed + 1 }

end Grpc.Channelz
