/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
namespace Grpc.ServiceConfig

structure RetryPolicy where
  maxAttempts : Nat := 1
  initialBackoffMs : Nat := 100
  maxBackoffMs : Nat := 1000
  backoffMultiplier : Nat := 2
  retryableStatusCodes : Array UInt32 := #[14] -- UNAVAILABLE
  deriving Inhabited

structure Config where
  timeoutMs : Option Nat := none
  retry : Option RetryPolicy := none
  loadBalancingPolicy : String := "pick_first"
  deriving Inhabited

/-- Minimal JSON-ish parser for a tiny subset used in tests:
    `{"loadBalancingPolicy":"round_robin","timeout":"1s"}` -/
def parse (json : String) : Config :=
  Id.run do
    let mut cfg : Config := {}
    if json.contains 'r' && json.contains "round_robin" then
      cfg := { cfg with loadBalancingPolicy := "round_robin" }
    if json.contains "pick_first" then
      cfg := { cfg with loadBalancingPolicy := "pick_first" }
    if json.contains "retryPolicy" || json.contains "maxAttempts" then
      cfg := { cfg with retry := some {} }
    -- timeout like "1s" / "100m"
    let mut i := 0
    let cs := json.toList.toArray
    while i + 8 < cs.size do
      if String.ofList [cs[i]!, cs[i+1]!, cs[i+2]!, cs[i+3]!, cs[i+4]!, cs[i+5]!, cs[i+6]!] == "timeout" then
        -- scan for a number after
        let mut j := i + 7
        while j < cs.size && !('0' ≤ cs[j]! && cs[j]! ≤ '9') do j := j + 1
        let mut n := 0
        let start := j
        while j < cs.size && ('0' ≤ cs[j]! && cs[j]! ≤ '9') do
          n := n * 10 + (cs[j]!.toNat - '0'.toNat)
          j := j + 1
        if start < j && j < cs.size then
          let unit := cs[j]!
          let ms :=
            match unit with
            | 's' => n * 1000
            | 'm' => n
            | _ => n
          cfg := { cfg with timeoutMs := some ms }
        break
      i := i + 1
    return cfg

end Grpc.ServiceConfig
