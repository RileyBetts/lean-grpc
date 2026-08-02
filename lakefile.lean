/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Lake
open Lake DSL
open System

package «lean-grpc» where
  version := v!"1.0.0"
  keywords := #["grpc", "http2", "hpack", "protobuf", "networking"]
  description := "Pure Lean 4 gRPC stack (HTTP/2 + HPACK + gRPC) on Std.Async"
  homepage := "https://rileybetts.ai/oss/lean-grpc"
  license := "Apache-2.0"
  licenseFiles := #["LICENSE", "NOTICE"]
  readmeFile := "README.md"
  -- OpenSSL link flags live on `Grpc` only (not Bytes/Hpack/H2), so non-gRPC
  -- targets need not pull `-lssl`. Peer gzip uses process helpers / stored
  -- deflate — `zlib_bridge.o` is unused by Lean FFI and is not linked here.

target tls_ffi.o pkg : FilePath := do
  let oFile := pkg.buildDir / "native" / "tls_ffi.o"
  let srcJob ← inputTextFile <| pkg.dir / "native" / "tls_ffi.c"
  let leanInc ← getLeanIncludeDir
  let mut incArgs : Array String := #["-fPIC", "-O2", "-I", leanInc.toString]
  let opensslCflags ← IO.Process.output { cmd := "pkg-config", args := #["--cflags", "openssl"] }
  if opensslCflags.exitCode == 0 then
    -- Split on spaces/newlines so trailing whitespace from pkg-config does not
    -- become a bare `cc` argument (breaks Lake buildO on Ubuntu runners).
    let cleaned := String.ofList <| opensslCflags.stdout.toList.map fun c =>
      if c.isWhitespace then ' ' else c
    for a in (cleaned.splitOn " ").filter (· ≠ "") do
      incArgs := incArgs.push a
  else
    let localInc := pkg.dir / ".lake" / "deps" / "openssl-3.0.13" / "include"
    if ← localInc.pathExists then
      incArgs := incArgs.push "-I" |>.push localInc.toString
  buildO oFile srcJob #[] incArgs

lean_lib Bytes
lean_lib Hpack
lean_lib H2
lean_lib Proto
/-- gRPC app surface. Links in-process OpenSSL (`tls_ffi`) for TLS/mTLS/ADC. -/
lean_lib Grpc where
  moreLinkObjs := #[tls_ffi.o]
  moreLinkArgs := #["-lssl", "-lcrypto"]

/-- Compile-time theorems for high-leverage pure codecs / maps (no runtime exe). -/
lean_lib Proofs

@[default_target]
lean_lib LeanGrpc

lean_exe bytesTests where
  root := `Tests.BytesMain

lean_exe hpackTests where
  root := `Tests.HpackMain

lean_exe h2Tests where
  root := `Tests.H2Main

lean_exe trailersServer where
  root := `Tests.TrailersServer

lean_exe trailersLoopback where
  root := `Tests.TrailersLoopback

lean_exe tlsServer where
  root := `Tests.TlsServer

lean_exe tlsLoopback where
  root := `Tests.TlsLoopback

lean_exe grpcTests where
  root := `Tests.GrpcMain

/-- Typed helloworld stubs (`./scripts/gen-helloworld.sh`). -/
lean_lib Helloworld where
  roots := #[`Examples.Helloworld.Generated]

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

lean_exe benchSoak where
  root := `Bench.Soak

lean_exe opsSmoke where
  root := `Tests.OpsSmoke

lean_exe h2specServer where
  root := `Tests.H2specServer

lean_exe routeGuideServer where
  root := `Examples.RouteGuide.Server

lean_exe routeGuideClient where
  root := `Examples.RouteGuide.Client

lean_lib VaultGauntlet where
  roots := #[`Examples.VaultGauntlet.Protocol]

lean_exe vaultGauntletServer where
  root := `Examples.VaultGauntlet.Server

lean_exe vaultGauntletClient where
  root := `Examples.VaultGauntlet.Client

lean_lib MirrorForge where
  roots := #[`Examples.MirrorForge.Protocol]

lean_exe mirrorForgeServer where
  root := `Examples.MirrorForge.Server

lean_exe mirrorForgeClient where
  root := `Examples.MirrorForge.Client

lean_lib SignalWeave where
  roots := #[`Examples.SignalWeave.Protocol]

lean_exe signalWeaveServer where
  root := `Examples.SignalWeave.Server

lean_lib FramingMatrix where
  roots := #[`Tests.FramingMatrix.Protocol]

lean_exe framingMatrixServer where
  root := `Tests.FramingMatrix.Server

lean_exe framingMatrixLeanClient where
  root := `Tests.FramingMatrix.LeanClient

lean_exe protocGenLean4Grpc where
  root := `Grpc.Codegen.Plugin
  exeName := "protoc-gen-lean4-grpc"

lean_exe fakeAdsServer where
  root := `Tests.FakeAdsServer

lean_exe adcSmoke where
  root := `Tests.AdcSmoke

lean_exe adcLive where
  root := `Tests.AdcLive

lean_exe securityTests where
  root := `Tests.SecurityMain
