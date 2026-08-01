/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc
import Examples.VaultGauntlet.Protocol

open Examples.VaultGauntlet.Protocol

/-- Multi-act vault heist server for protocol stress-testing. -/
def main : IO Unit := do
  let port := ((← IO.getEnv "GRPC_PORT").getD "50177").toNat?.getD 50177 |>.toUInt16
  let health ← IO.mkRef Grpc.Health.ServingStatus.serving
  let nonceBox ← IO.mkRef (1 : UInt32)
  let mut s := Grpc.Server.empty

  -- Act I: Enlist (unary + binary session token in body)
  s := Grpc.Server.register s serviceName "Enlist" fun reqBytes => do
    let req ← IO.ofExcept (EnlistRequest.decode reqBytes)
    if req.name.isEmpty then
      return (ByteArray.empty, Grpc.Status.invalidArgument "name required")
    let n ← nonceBox.modifyGet fun n => (n, n + 1)
    let tok := mintToken req.name n
    let reply := EnlistReply.encode { token := tok, nonce := n }
    return (reply, Grpc.Status.ok)

  -- Act II: Clues (server streaming)
  s := Grpc.Server.registerServerStream s serviceName "Clues" fun reqBytes => do
    let _ ← IO.ofExcept (EnlistReply.decode reqBytes)  -- token echo as auth proof
    let clues : Array Clue := #[
      { index := 1, text := "LEAN-" },
      { index := 2, text := "GRPC-" },
      { index := 3, text := "OPEN" }
    ]
    let msgs := clues.map Clue.encode
    return (msgs, Grpc.Status.ok)

  -- Act III: DepositShards (client streaming; peer may gzip each frame)
  s := Grpc.Server.registerClientStream s serviceName "DepositShards" fun msgs => do
    if msgs.size < 3 then
      return (ByteArray.empty, Grpc.Status.invalidArgument "need ≥3 shards")
    let mut x : UInt32 := 0
    for m in msgs do
      let shard ← IO.ofExcept (Shard.decode m)
      x := x ^^^ foldXor shard.material
    let reply := DepositReply.encode { xorFold := x, count := msgs.size.toUInt32 }
    return (reply, Grpc.Status.ok)

  -- Act IV: PickLock (bidi — buffered until half-close)
  s := Grpc.Server.registerBidi s serviceName "PickLock" fun msgs => do
    let mut out : Array ByteArray := #[]
    let mut opened := false
    for m in msgs do
      let attempt ← IO.ofExcept (PickAttempt.decode m)
      if opened then
        out := out.push (PickHint.encode { opened := true, hint := "already open" })
      else if attempt.guess == vaultPassword then
        opened := true
        out := out.push (PickHint.encode { opened := true, hint := "vault opened" })
      else if attempt.guess.isEmpty then
        out := out.push (PickHint.encode { opened := false, hint := "empty guess" })
      else
        let warmth :=
          if vaultPassword.isPrefixOf attempt.guess || attempt.guess.isPrefixOf vaultPassword then
            "warm"
          else
            "cold"
        out := out.push (PickHint.encode { opened := false, hint := warmth })
    if out.isEmpty then
      out := #[PickHint.encode { opened := false, hint := "no attempts" }]
    let st : Grpc.Status :=
      if opened then Grpc.Status.ok
      else { code := .failedPrecondition, message := "still sealed" }
    return (out, st)

  -- Act V: Sabotage — INTERNAL with google.rpc.Status details
  s := Grpc.Server.register s serviceName "Sabotage" fun _ => do
    let st0 : Grpc.Status := { code := .internal, message := "alarm triggered" }
    let details := Grpc.StatusDetails.encode st0 #[
      { typeUrl := "type.googleapis.com/vault.gauntlet.Alarm", value := "siren".toUTF8 }
    ]
    let st : Grpc.Status := { st0 with detailsBin := some details }
    return (ByteArray.empty, st)

  -- Act VI helper: Sleepy — ignores request and stalls (deadline probe)
  s := Grpc.Server.register s serviceName "Sleepy" fun _ => do
    IO.sleep 2000
    return (ByteArray.empty, Grpc.Status.ok)

  s := Grpc.Health.registerWithWatch s health
  IO.println s!"VaultGauntlet listening on 127.0.0.1:{port.toNat}"
  Grpc.Server.serveH2c s { host := "127.0.0.1", port }
