/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Server
import Grpc.Status
import Grpc.Stream
import Proto.Wire
import Bytes.Slice

namespace Grpc.Reflection

/-- `grpc.reflection.v1[alpha].ServerReflectionRequest` (subset of the `message_request` oneof:
    `list_services`, `file_by_filename`, `file_containing_symbol`). -/
structure Request where
  host : String := ""
  fileByFilename : Option String := none
  fileContainingSymbol : Option String := none
  listServices : Option String := none
  deriving Inhabited

def Request.decode (b : ByteArray) : Except String Request := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  return {
    host := (Proto.Wire.fieldString? fields 1).getD ""
    fileByFilename := Proto.Wire.fieldString? fields 3
    fileContainingSymbol := Proto.Wire.fieldString? fields 4
    listServices := Proto.Wire.fieldString? fields 7
  }

private def encodeRequestOneof (r : Request) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !r.host.isEmpty then acc := Proto.Wire.encodeString acc 1 r.host
    if let some f := r.fileByFilename then acc := Proto.Wire.encodeString acc 3 f
    if let some sym := r.fileContainingSymbol then acc := Proto.Wire.encodeString acc 4 sym
    if let some ls := r.listServices then acc := Proto.Wire.encodeString acc 7 ls
    return acc

def Request.encode (r : Request) : ByteArray := encodeRequestOneof r

/-- Convenience: build a `list_services` request (client → server). -/
def listServicesRequest (host : String := "") : ByteArray :=
  Request.encode { host, listServices := some "" }

/-- Convenience: build a `file_by_filename` request. -/
def fileByFilenameRequest (filename : String) (host : String := "") : ByteArray :=
  Request.encode { host, fileByFilename := some filename }

/-- `ServiceResponse { name = 1 }`. -/
private def encodeServiceResponse (name : String) : ByteArray :=
  Proto.Wire.encodeString ByteArray.empty 1 name

/-- `ListServiceResponse { repeated ServiceResponse service = 1 }`. -/
private def encodeListServicesResponse (services : Array String) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    for name in services do
      acc := Proto.Wire.encodeMessage acc 1 (encodeServiceResponse name)
    return acc

/-- `FileDescriptorResponse { repeated bytes file_descriptor_proto = 1 }`. -/
private def encodeFileDescriptorResponse (fds : Array ByteArray) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    for fd in fds do acc := Proto.Wire.encodeBytes acc 1 fd
    return acc

/-- `ErrorResponse { error_code = 1; error_message = 2 }`. -/
private def encodeErrorResponse (code : Int32) (message : String) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    acc := Proto.Wire.encodeUInt32 acc 1 code.toUInt32
    acc := Proto.Wire.encodeString acc 2 message
    return acc

/-- `ServerReflectionResponse { valid_host = 1; message_response = <field> }`. -/
private def encodeResponse (validHost : String) (field : Nat) (payload : ByteArray) : ByteArray :=
  Id.run do
    let mut acc := ByteArray.empty
    if !validHost.isEmpty then acc := Proto.Wire.encodeString acc 1 validHost
    acc := Proto.Wire.encodeMessage acc field payload
    return acc

/-- List-of-service names + optional filename → file-descriptor-proto-bytes lookup table
    (a minimal in-memory "descriptor pool" — enough to answer `file_by_filename` and
    `file_containing_symbol` for services that register their raw `FileDescriptorProto` bytes). -/
structure Registry where
  services : Array String := #[]
  /-- `(filename, FileDescriptorProto bytes)`. -/
  files : Array (String × ByteArray) := #[]
  /-- `(fully-qualified symbol, filename)`, used to resolve `file_containing_symbol`. -/
  symbolToFile : Array (String × String) := #[]
  deriving Inhabited

private def fieldNotFound : Int32 := 5 -- google.rpc.Code.NOT_FOUND
private def fieldUnimplemented : Int32 := 12 -- google.rpc.Code.UNIMPLEMENTED

private def respond (reg : Registry) (req : Request) : ByteArray :=
  if req.listServices.isSome then
    encodeResponse req.host 6 (encodeListServicesResponse reg.services)
  else if let some fname := req.fileByFilename then
    match reg.files.find? (fun (n, _) => n == fname) with
    | some (_, fd) => encodeResponse req.host 4 (encodeFileDescriptorResponse #[fd])
    | none => encodeResponse req.host 7 (encodeErrorResponse fieldNotFound s!"file not found: {fname}")
  else if let some sym := req.fileContainingSymbol then
    match reg.symbolToFile.find? (fun (s, _) => s == sym) with
    | some (_, fname) =>
      match reg.files.find? (fun (n, _) => n == fname) with
      | some (_, fd) => encodeResponse req.host 4 (encodeFileDescriptorResponse #[fd])
      | none => encodeResponse req.host 7 (encodeErrorResponse fieldNotFound s!"file not found: {fname}")
    | none => encodeResponse req.host 7 (encodeErrorResponse fieldNotFound s!"symbol not found: {sym}")
  else
    encodeResponse req.host 7 (encodeErrorResponse fieldUnimplemented "unsupported reflection request")

/-- Register `ServerReflectionInfo` (bidi-streaming in the real proto; a single
    request/response pair also works fine as a plain unary call, which is how
    `Tests/OpsSmoke` exercises it). -/
private def registerFor (s : Server) (fullService : String) (reg : Registry) : Server :=
  let h : Stream.BidiStreamHandler := fun reqs => do
    let mut out : Array ByteArray := #[]
    for reqBytes in reqs do
      match Request.decode reqBytes with
      | .ok req => out := out.push (respond reg req)
      | .error _ => pure ()
    return (out, Status.ok)
  Server.registerBidi s fullService "ServerReflectionInfo" h

/-- Register real(-ish) `grpc.reflection.v1alpha.ServerReflection`. -/
def registerV1Alpha (s : Server) (reg : Registry) : Server :=
  registerFor s "grpc.reflection.v1alpha.ServerReflection" reg

/-- Register real(-ish) `grpc.reflection.v1.ServerReflection`. -/
def registerV1 (s : Server) (reg : Registry) : Server :=
  registerFor s "grpc.reflection.v1.ServerReflection" reg

/-- Register both the `v1` and `v1alpha` reflection services against the same registry. -/
def register (s : Server) (services : Array String) (files : Array (String × ByteArray) := #[])
    (symbolToFile : Array (String × String) := #[]) : Server :=
  let reg : Registry := { services, files, symbolToFile }
  registerV1 (registerV1Alpha s reg) reg

/-! # Client-side response decode (`ServerReflectionResponse`). -/

structure Response where
  validHost : String := ""
  services : Option (Array String) := none
  fileDescriptorProtos : Option (Array ByteArray) := none
  errorCode : Option Int32 := none
  errorMessage : String := ""
  deriving Inhabited

private def decodeListServicesResponse (b : ByteArray) : Array String :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b) with
  | .error _ => #[]
  | .ok fields =>
    (Proto.Wire.fieldBytesMany fields 1).map fun svcBytes =>
      match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray svcBytes) with
      | .ok svcFields => (Proto.Wire.fieldString? svcFields 1).getD ""
      | .error _ => ""

private def decodeErrorResponse (b : ByteArray) : Int32 × String :=
  match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b) with
  | .error _ => (0, "")
  | .ok fields => ((Proto.Wire.fieldUInt32? fields 1).getD 0 |>.toInt32,
      (Proto.Wire.fieldString? fields 2).getD "")

def Response.decode (b : ByteArray) : Except String Response := do
  let fields ← Proto.Wire.decodeFields (Bytes.Slice.ofByteArray b)
  let validHost := (Proto.Wire.fieldString? fields 1).getD ""
  let services := (Proto.Wire.fieldBytes? fields 6).map decodeListServicesResponse
  let fileDescriptorProtos :=
    (Proto.Wire.fieldBytes? fields 4).map fun fdBytes =>
      match Proto.Wire.decodeFields (Bytes.Slice.ofByteArray fdBytes) with
      | .ok fdFields => Proto.Wire.fieldBytesMany fdFields 1
      | .error _ => #[]
  let (errorCode, errorMessage) :=
    match (Proto.Wire.fieldBytes? fields 7).map decodeErrorResponse with
    | some (code, msg) => (some code, msg)
    | none => (none, "")
  return { validHost, services, fileDescriptorProtos, errorCode, errorMessage }

end Grpc.Reflection
