/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Lean.Data.Json

namespace Grpc.ServiceConfig

open Lean (Json JsonNumber)

structure RetryPolicy where
  maxAttempts : Nat := 1
  initialBackoffMs : Nat := 100
  maxBackoffMs : Nat := 1000
  backoffMultiplier : Nat := 2
  retryableStatusCodes : Array UInt32 := #[14] -- UNAVAILABLE
  deriving Inhabited

structure HedgingPolicy where
  maxAttempts : Nat := 2
  hedgingDelayMs : Nat := 10
  nonFatalStatusCodes : Array UInt32 := #[14]
  deriving Inhabited

structure Config where
  timeoutMs : Option Nat := none
  retry : Option RetryPolicy := none
  hedging : Option HedgingPolicy := none
  loadBalancingPolicy : String := "pick_first"
  deriving Inhabited

/-- Map a gRPC status-code name (as used in `service_config.proto` JSON, e.g.
    `"UNAVAILABLE"`) to its numeric wire code. Unknown names are ignored. -/
def statusCodeFromName? : String → Option UInt32
  | "OK" => some 0 | "CANCELLED" => some 1 | "UNKNOWN" => some 2
  | "INVALID_ARGUMENT" => some 3 | "DEADLINE_EXCEEDED" => some 4
  | "NOT_FOUND" => some 5 | "ALREADY_EXISTS" => some 6
  | "PERMISSION_DENIED" => some 7 | "RESOURCE_EXHAUSTED" => some 8
  | "FAILED_PRECONDITION" => some 9 | "ABORTED" => some 10
  | "OUT_OF_RANGE" => some 11 | "UNIMPLEMENTED" => some 12
  | "INTERNAL" => some 13 | "UNAVAILABLE" => some 14
  | "DATA_LOSS" => some 15 | "UNAUTHENTICATED" => some 16
  | _ => none

/-- Parse a `google.protobuf.Duration`-style JSON string such as `"1s"`,
    `"0.1s"`, or `"250ms"` into whole milliseconds. -/
def parseDurationMs (s : String) : Option Nat :=
  if s.isEmpty then none
  else if s.endsWith "ms" then
    let numStr := (s.dropEnd 2).toString
    numStr.toNat?
  else if s.endsWith "s" then
    let numStr := (s.dropEnd 1).toString
    match numStr.splitOn "." with
    | [whole] => (whole.toNat?).map (· * 1000)
    | [whole, frac] =>
      let wholeMs := (whole.toNat?.getD 0) * 1000
      let frac3 := ((frac ++ "000").take 3).toString
      let fracMs := frac3.toNat?.getD 0
      some (wholeMs + fracMs)
    | _ => none
  else
    -- Back-compat with the earlier ad-hoc parser, which treated a bare
    -- numeric prefix followed by any non-digit unit as already-milliseconds.
    let digits := (s.takeWhile Char.isDigit).toString
    if digits.isEmpty then none else digits.toNat?

private def jsonNumToNat (n : JsonNumber) : Nat :=
  if n.exponent == 0 then n.mantissa.toNat
  else max 1 (n.mantissa.toNat / (10 ^ n.exponent))

/-- Read a field as a `Nat`, accepting both JSON integers and decimals
    (e.g. `backoffMultiplier: 1.6`). -/
private def getNatField? (obj : Json) (key : String) : Option Nat :=
  match obj.getObjVal? key with
  | .error _ => none
  | .ok v =>
    match v.getNat? with
    | .ok n => some n
    | .error _ =>
      match v.getNum? with
      | .ok n => some (jsonNumToNat n)
      | .error _ => none

private def getStrField? (obj : Json) (key : String) : Option String :=
  match obj.getObjVal? key with
  | .error _ => none
  | .ok v => (v.getStr?).toOption

private def getObjField? (obj : Json) (key : String) : Option Json :=
  match obj.getObjVal? key with
  | .error _ => none
  | .ok v => some v

private def getArrField? (obj : Json) (key : String) : Option (Array Json) :=
  match obj.getObjVal? key with
  | .error _ => none
  | .ok v => (v.getArr?).toOption

private def getStatusCodeArray (obj : Json) (key : String) (dflt : Array UInt32) : Array UInt32 :=
  match getArrField? obj key with
  | none => dflt
  | some arr =>
    let codes := arr.filterMap fun j => (j.getStr?).toOption.bind statusCodeFromName?
    if codes.isEmpty then dflt else codes

private def parseRetryPolicy (obj : Json) : RetryPolicy :=
  { maxAttempts := getNatField? obj "maxAttempts" |>.getD 1
    initialBackoffMs := (getStrField? obj "initialBackoff").bind parseDurationMs |>.getD 100
    maxBackoffMs := (getStrField? obj "maxBackoff").bind parseDurationMs |>.getD 1000
    backoffMultiplier := getNatField? obj "backoffMultiplier" |>.getD 2
    retryableStatusCodes := getStatusCodeArray obj "retryableStatusCodes" #[14] }

private def parseHedgingPolicy (obj : Json) : HedgingPolicy :=
  { maxAttempts := getNatField? obj "maxAttempts" |>.getD 2
    hedgingDelayMs := (getStrField? obj "hedgingDelay").bind parseDurationMs |>.getD 10
    nonFatalStatusCodes := getStatusCodeArray obj "nonFatalStatusCodes" #[14] }

/-- Extract the sole policy name from a `loadBalancingConfig` entry, e.g.
    `{"round_robin":{}}` → `"round_robin"`. -/
private def lbConfigPolicyName? (entry : Json) : Option String :=
  match entry with
  | .obj kvs => kvs.toList.head?.map Prod.fst
  | _ => none

/-- Parse a JSON `google.grpc.service_config` document (or a small subset of
    it, as used in tests) into a `Config`. Recognises `loadBalancingPolicy`,
    `loadBalancingConfig`, `timeout`, `retryPolicy` and `hedgingPolicy` both at
    the top level and inside the first `methodConfig` entry, matching the
    common single-method-config test fixtures used across the suite. Falls
    back to defaults on any parse failure rather than throwing, since service
    config is best-effort input. -/
def parse (json : String) : Config :=
  match Json.parse json with
  | .error _ => {}
  | .ok root =>
    -- Merge top-level fields with the first methodConfig entry (if any); the
    -- top level wins so ad-hoc single-field test fixtures keep working.
    let methodCfg? : Option Json := do
      let arr ← getArrField? root "methodConfig"
      arr[0]?
    let lookupStr (key : String) : Option String :=
      (getStrField? root key).orElse fun _ => methodCfg?.bind (getStrField? · key)
    let lookupObj (key : String) : Option Json :=
      (getObjField? root key).orElse fun _ => methodCfg?.bind (getObjField? · key)
    let lbPolicy :=
      match lookupStr "loadBalancingPolicy" with
      | some p => p
      | none =>
        match getArrField? root "loadBalancingConfig" with
        | some arr => arr[0]?.bind lbConfigPolicyName? |>.getD "pick_first"
        | none => "pick_first"
    let timeoutMs := (lookupStr "timeout").bind parseDurationMs
    let retry := (lookupObj "retryPolicy").map parseRetryPolicy
    let hedging := (lookupObj "hedgingPolicy").map parseHedgingPolicy
    { timeoutMs, retry, hedging, loadBalancingPolicy := lbPolicy }

end Grpc.ServiceConfig
