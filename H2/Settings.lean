/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
namespace H2

structure Settings where
  headerTableSize : UInt32 := 4096
  enablePush : Bool := true
  maxConcurrentStreams : UInt32 := 100
  initialWindowSize : UInt32 := 65535
  maxFrameSize : UInt32 := 16384
  -- Uncompressed list size (RFC 9113). Keep high enough for h2spec CONTINUATION
  -- (CommonHeaders + 2× DummyHeaders at --max-header-length=4000) while still
  -- bounding memory; securityTests override to a tiny value.
  maxHeaderListSize : UInt32 := 262144
  deriving Inhabited

inductive SettingId where
  | headerTableSize
  | enablePush
  | maxConcurrentStreams
  | initialWindowSize
  | maxFrameSize
  | maxHeaderListSize
  | other (n : UInt16)
  deriving BEq

def SettingId.toU16 : SettingId → UInt16
  | .headerTableSize => 1
  | .enablePush => 2
  | .maxConcurrentStreams => 3
  | .initialWindowSize => 4
  | .maxFrameSize => 5
  | .maxHeaderListSize => 6
  | .other n => n

def SettingId.ofU16 (n : UInt16) : SettingId :=
  match n with
  | 1 => .headerTableSize
  | 2 => .enablePush
  | 3 => .maxConcurrentStreams
  | 4 => .initialWindowSize
  | 5 => .maxFrameSize
  | 6 => .maxHeaderListSize
  | n => .other n

def Settings.apply (s : Settings) (id : SettingId) (v : UInt32) : Except String Settings :=
  match id with
  | .headerTableSize => pure { s with headerTableSize := v }
  | .enablePush =>
    if v > 1 then throw "ENABLE_PUSH invalid" else pure { s with enablePush := v == 1 }
  | .maxConcurrentStreams => pure { s with maxConcurrentStreams := v }
  | .initialWindowSize =>
    if v > 0x7fffffff then throw "window too large" else pure { s with initialWindowSize := v }
  | .maxFrameSize =>
    if v < 16384 ∨ v > 16777215 then throw "bad max frame size"
    else pure { s with maxFrameSize := v }
  | .maxHeaderListSize => pure { s with maxHeaderListSize := v }
  | .other _ => pure s

end H2
