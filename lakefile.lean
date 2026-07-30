/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Lake
open Lake DSL

package «lean-grpc» where
  version := v!"0.1.0"
  keywords := #["grpc", "http2", "hpack", "protobuf", "networking"]
  description := "Pure Lean 4 gRPC stack (HTTP/2 + HPACK + gRPC) on Std.Async"

lean_lib Bytes
lean_lib Hpack
lean_lib H2
lean_lib Proto
lean_lib Grpc

@[default_target]
lean_lib LeanGrpc

lean_exe bytesTests where
  root := `Tests.BytesMain

lean_exe hpackTests where
  root := `Tests.HpackMain

lean_exe h2Tests where
  root := `Tests.H2Main

lean_exe grpcTests where
  root := `Tests.GrpcMain

lean_exe helloworldServer where
  root := `Examples.Helloworld.Server

lean_exe helloworldClient where
  root := `Examples.Helloworld.Client

lean_exe interopServer where
  root := `Tests.Interop.Server

lean_exe interopClient where
  root := `Tests.Interop.Client

lean_exe benchUnary where
  root := `Bench.Unary

lean_exe protocGenLean4Grpc where
  root := `Grpc.Codegen.Plugin
  exeName := "protoc-gen-lean4-grpc"
