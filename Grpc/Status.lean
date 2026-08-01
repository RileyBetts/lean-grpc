/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
namespace Grpc

inductive StatusCode where
  | ok | cancelled | unknown | invalidArgument | deadlineExceeded
  | notFound | alreadyExists | permissionDenied | resourceExhausted
  | failedPrecondition | aborted | outOfRange | unimplemented
  | internal | unavailable | dataLoss | unauthenticated
  deriving BEq, Inhabited

def StatusCode.toUInt32 : StatusCode → UInt32
  | .ok => 0 | .cancelled => 1 | .unknown => 2 | .invalidArgument => 3
  | .deadlineExceeded => 4 | .notFound => 5 | .alreadyExists => 6
  | .permissionDenied => 7 | .resourceExhausted => 8 | .failedPrecondition => 9
  | .aborted => 10 | .outOfRange => 11 | .unimplemented => 12
  | .internal => 13 | .unavailable => 14 | .dataLoss => 15 | .unauthenticated => 16

def StatusCode.ofUInt32 : UInt32 → StatusCode
  | 0 => .ok | 1 => .cancelled | 2 => .unknown | 3 => .invalidArgument
  | 4 => .deadlineExceeded | 5 => .notFound | 6 => .alreadyExists
  | 7 => .permissionDenied | 8 => .resourceExhausted | 9 => .failedPrecondition
  | 10 => .aborted | 11 => .outOfRange | 12 => .unimplemented
  | 13 => .internal | 14 => .unavailable | 15 => .dataLoss | 16 => .unauthenticated
  | _ => .unknown

structure Status where
  code : StatusCode := .ok
  message : String := ""
  /-- Optional encoded `google.rpc.Status` details (wire bytes of details-only payload). -/
  detailsBin : Option ByteArray := none
  deriving Inhabited

instance : BEq Status where
  beq a b := a.code == b.code && a.message == b.message &&
    match a.detailsBin, b.detailsBin with
    | none, none => true
    | some x, some y => x == y
    | _, _ => false

def Status.ok : Status := {}
def Status.unimplemented (msg : String := "") : Status := { code := .unimplemented, message := msg }
def Status.internal (msg : String) : Status := { code := .internal, message := msg }
def Status.resourceExhausted (msg : String) : Status := { code := .resourceExhausted, message := msg }
def Status.cancelled (msg : String := "") : Status := { code := .cancelled, message := msg }
def Status.deadlineExceeded (msg : String := "deadline exceeded") : Status :=
  { code := .deadlineExceeded, message := msg }
def Status.unavailable (msg : String := "") : Status := { code := .unavailable, message := msg }
def Status.invalidArgument (msg : String := "") : Status := { code := .invalidArgument, message := msg }
def Status.permissionDenied (msg : String := "") : Status := { code := .permissionDenied, message := msg }
def Status.unauthenticated (msg : String := "") : Status := { code := .unauthenticated, message := msg }

end Grpc

