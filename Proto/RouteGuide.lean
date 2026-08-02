/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes.Slice
import Proto.Wire

namespace Proto

/-- routeguide.Point -/
structure Point where
  latitude : Int := 0
  longitude : Int := 0
  deriving Inhabited, BEq

def Point.encode (p : Point) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if p.latitude != 0 then
      acc := Wire.encodeUInt32 acc 1 (UInt32.ofNat (p.latitude.toNat))
    if p.longitude != 0 then
      acc := Wire.encodeUInt32 acc 2 (UInt32.ofNat (p.longitude.toNat))
    return acc

def Point.decode (b : ByteArray) : Except String Point := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    latitude := ((Wire.fieldUInt32? fields 1).getD 0).toNat
    longitude := ((Wire.fieldUInt32? fields 2).getD 0).toNat
  }

/-- Nested Rectangle { Point lo = 1; Point hi = 2; } -/
structure Rectangle where
  lo : Point := {}
  hi : Point := {}
  deriving Inhabited, BEq

def Rectangle.encode (r : Rectangle) : ByteArray :=
  Wire.encodeMessage (Wire.encodeMessage ByteArray.empty 1 (Point.encode r.lo)) 2 (Point.encode r.hi)

def Rectangle.decode (b : ByteArray) : Except String Rectangle := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let lo ←
    match Wire.fieldBytes? fields 1 with
    | none => pure {}
    | some bb => Point.decode bb
  let hi ←
    match Wire.fieldBytes? fields 2 with
    | none => pure {}
    | some bb => Point.decode bb
  return { lo, hi }

structure Feature where
  name : String := ""
  location : Point := {}
  deriving Inhabited, BEq

def Feature.encode (f : Feature) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !f.name.isEmpty then acc := Wire.encodeString acc 1 f.name
    acc := Wire.encodeMessage acc 2 (Point.encode f.location)
    return acc

def Feature.decode (b : ByteArray) : Except String Feature := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let location ←
    match Wire.fieldBytes? fields 2 with
    | none => pure {}
    | some bb => Point.decode bb
  return { name := (Wire.fieldString? fields 1).getD "", location }

structure RouteNote where
  location : Point := {}
  message : String := ""
  deriving Inhabited, BEq

def RouteNote.encode (n : RouteNote) : ByteArray :=
  Id.run do
    let mut acc := Wire.encodeMessage ByteArray.empty 1 (Point.encode n.location)
    if !n.message.isEmpty then acc := Wire.encodeString acc 2 n.message
    return acc

def RouteNote.decode (b : ByteArray) : Except String RouteNote := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let location ←
    match Wire.fieldBytes? fields 1 with
    | none => pure {}
    | some bb => Point.decode bb
  return { location, message := (Wire.fieldString? fields 2).getD "" }

structure RouteSummary where
  pointCount : UInt32 := 0
  featureCount : UInt32 := 0
  distance : UInt32 := 0
  elapsedTime : UInt32 := 0
  deriving Inhabited, BEq

def RouteSummary.encode (s : RouteSummary) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if s.pointCount != 0 then acc := Wire.encodeUInt32 acc 1 s.pointCount
    if s.featureCount != 0 then acc := Wire.encodeUInt32 acc 2 s.featureCount
    if s.distance != 0 then acc := Wire.encodeUInt32 acc 3 s.distance
    if s.elapsedTime != 0 then acc := Wire.encodeUInt32 acc 4 s.elapsedTime
    return acc

def RouteSummary.decode (b : ByteArray) : Except String RouteSummary := do
  let fields ← Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    pointCount := (Wire.fieldUInt32? fields 1).getD 0
    featureCount := (Wire.fieldUInt32? fields 2).getD 0
    distance := (Wire.fieldUInt32? fields 3).getD 0
    elapsedTime := (Wire.fieldUInt32? fields 4).getD 0
  }

end Proto
