/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2.Connection
import H2.Frame

namespace Proofs.ConnState

open H2

/-! ## Helpers -/

/-- Build a byte array of `n` copies of `v`. -/
private def rep (n : Nat) (v : UInt8) : ByteArray :=
  ByteArray.mk (Array.replicate n v)

/-- A server `ConnState` with `expectContinuation = some sid`. -/
private def stWithCont (sid : UInt32) : ConnState :=
  { ConnState.create with expectContinuation := some sid }

/-- Check that `handleFrame` on `(st, f)` returns GOAWAY and sets `wentAway`. -/
private def causesConnError (st : ConnState) (f : Frame) : Bool :=
  match handleFrame st f with
  | .ok (st', frames) => st'.wentAway && frames.any (·.type == .goAway)
  | .error _ => false

/-- Check that `handleFrame` does NOT produce a connection error. -/
private def noConnError (st : ConnState) (f : Frame) : Bool :=
  match handleFrame st f with
  | .ok (st', _) => !st'.wentAway
  | .error _ => false

/-- Check that after `handleFrame` the `wentAway` flag is true. -/
private def setsWentAway (st : ConnState) (f : Frame) : Bool :=
  match handleFrame st f with
  | .ok (st', _) => st'.wentAway
  | .error _ => false

/-- Check that recv windows stay ≥ 0 after one DATA frame. -/
private def recvWindowsNonneg (st : ConnState) (f : Frame) : Bool :=
  match handleFrame st f with
  | .ok (st', _) =>
    (st'.recvConnWindow ≥ 0) &&
    st'.streams.all (·.recvWindow ≥ 0)
  | .error _ => false

/-! ## Theorem 1 — CONTINUATION sequencing

If `expectContinuation` is set, any frame whose type is **not** CONTINUATION
must be rejected with a connection error (GOAWAY). -/

theorem continuation_gate_data :
    causesConnError (stWithCont 1) ⟨.data, Flags.endStream, 1, rep 1 0x68⟩ = true := by
  native_decide

theorem continuation_gate_headers :
    causesConnError (stWithCont 1) ⟨.headers, Flags.endHeaders, 3, rep 1 0x82⟩ = true := by
  native_decide

theorem continuation_gate_ping :
    causesConnError (stWithCont 1) ⟨.ping, Flags.none, 0, rep 8 0⟩ = true := by
  native_decide

theorem continuation_gate_windowUpdate :
    causesConnError (stWithCont 1) (Frame.windowUpdate 1 1024) = true := by
  native_decide

/-- CONTINUATION for the wrong stream id is a connection error. -/
theorem continuation_gate_wrong_stream :
    causesConnError (stWithCont 1) ⟨.continuation, Flags.endHeaders, 3, rep 1 0x82⟩ = true := by
  native_decide

/-- CONTINUATION for the correct stream is accepted when a stream is open for that id. -/
private def stWithContAndStream (sid : UInt32) : ConnState :=
  let s := { Stream.create sid 65535 65535 with state := .open }
  { ConnState.create (isServer := false) with
    expectContinuation := some sid
    streams := #[s] }

theorem continuation_accepts_correct_stream :
    noConnError (stWithContAndStream 1)
      ⟨.continuation, Flags.endHeaders, 1, rep 1 0x82⟩ = true := by
  native_decide

/-! ## Theorem 2 — Non-negative receive windows -/

private def openStreamState : ConnState :=
  let s0 := Stream.create 1 65535 65535
  { ConnState.create with streams := #[{ s0 with state := .open }] }

theorem recvWindow_nonneg_single_data :
    recvWindowsNonneg openStreamState ⟨.data, Flags.none, 1, rep 100 0x61⟩ = true := by
  native_decide

theorem recvWindow_nonneg_after_window_update :
    (match handleFrame openStreamState ⟨.data, Flags.none, 1, rep 50 0x61⟩ with
     | .ok (st1, _) =>
       match handleFrame st1 (Frame.windowUpdate 0 4096) with
       | .ok (st2, _) => st2.recvConnWindow ≥ 0
       | .error _ => false
     | .error _ => false) = true := by
  native_decide

/-- DATA exceeding the connection recv window triggers FLOW_CONTROL GOAWAY. -/
theorem recvWindow_overflow_triggers_goaway :
    causesConnError openStreamState ⟨.data, Flags.none, 1, rep 65536 0x61⟩ = true := by
  native_decide

/-! ## Theorem 3 — `ENHANCE_YOUR_CALM` on oversized header list -/

private def stTinyMaxList : ConnState :=
  ConnState.create { ourSettings := { maxHeaderListSize := 10 } } (isServer := true)

/-- A raw header block larger than `maxHeaderListSize` triggers GOAWAY ENHANCE_YOUR_CALM. -/
theorem enhanceYourCalm_compressed_oversize :
    (match handleFrame stTinyMaxList ⟨.headers, Flags.endHeaders, 1, rep 200 0x82⟩ with
     | .ok (st', frames) =>
       st'.wentAway && frames.any (fun frm =>
         frm.type == .goAway &&
         (Bytes.BE.readU32 (Bytes.Slice.ofByteArray frm.payload) 4 |>.getD 0) == 0xb)
     | .error _ => false) = true := by
  native_decide

/-- A header block within the limit is accepted without connection error (client mode). -/
theorem enhanceYourCalm_within_limit_ok :
    noConnError (ConnState.create { ourSettings := { maxHeaderListSize := 65535 } } (isServer := false))
      ⟨.headers, Flags.endHeaders, 1, ByteArray.mk #[0x82]⟩ = true := by
  native_decide

/-! ## Theorem 4 — GOAWAY stops new streams -/

private def stAfterGoaway : ConnState :=
  { ConnState.create (isServer := true) with wentAway := true, lastPeerStreamId := 3 }

/-- HEADERS for a new stream (id > lastPeerStreamId) after GOAWAY is rejected. -/
theorem goaway_gates_new_streams :
    causesConnError stAfterGoaway ⟨.headers, Flags.endHeaders, 5, ByteArray.mk #[0x82]⟩ = true := by
  native_decide

/-- HEADERS for a stream id ≤ lastPeerStreamId and not already open is rejected. -/
theorem goaway_gates_already_seen_stream :
    causesConnError { stAfterGoaway with lastPeerStreamId := 5 }
      ⟨.headers, Flags.endHeaders, 3, ByteArray.mk #[0x82]⟩ = true := by
  native_decide

/-- Receiving a GOAWAY frame sets `wentAway`. -/
theorem goaway_frame_sets_wentAway :
    setsWentAway ConnState.create ⟨.goAway, Flags.none, 0, rep 8 0⟩ = true := by
  native_decide

end Proofs.ConnState
