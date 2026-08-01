/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Proto.WellKnown
import Grpc.Status
import Grpc.Metadata

namespace Grpc.StatusDetails

open Proto.WellKnown

/-- Build `google.rpc.Status` bytes for a gRPC Status (code must not be OK when attached). -/
def encode (st : Status) (details : Array AnyMsg := #[]) : ByteArray :=
  RpcStatus.encode {
    code := st.code.toUInt32.toInt32
    message := st.message
    details
  }

/-- Decode `grpc-status-details-bin` payload. Rejects when embedded code contradicts `statusCode`. -/
def decode (payload : ByteArray) (statusCode : StatusCode) : Except String RpcStatus := do
  let rpc ← RpcStatus.decode payload
  let wireCode := StatusCode.ofUInt32 rpc.code.toUInt32
  if wireCode != statusCode && statusCode != .ok then
    -- PROTOCOL-HTTP2: if details contain a status code it MUST NOT contradict Status.
    if rpc.code.toUInt32 != statusCode.toUInt32 then
      throw s!"status-details code {rpc.code} contradicts grpc-status {statusCode.toUInt32}"
  pure rpc

/-- Attach `grpc-status-details-bin` when status ≠ OK. -/
def attachBin (md : Metadata) (st : Status) (details : Array AnyMsg := #[]) : Metadata :=
  if st.code == .ok then md
  else Metadata.addBin md "grpc-status-details" (encode st details)

/-- Read and validate status details from trailers/headers metadata. -/
def fromMetadata (m : Metadata) (statusCode : StatusCode) : Except String (Option RpcStatus) := do
  match ← Metadata.getBin? m "grpc-status-details-bin" with
  | none => pure none
  | some bytes =>
    if statusCode == .ok then
      throw "grpc-status-details-bin not allowed when status is OK"
    some <$> decode bytes statusCode

end Grpc.StatusDetails
