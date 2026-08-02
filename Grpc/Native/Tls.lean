/-
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
Released under Apache 2.0 license as described in the file LICENSE.
-/
import H2.Transport

namespace Grpc.Native.Tls

private opaque ConnImpl.Pointed : NonemptyType.{0}
/-- OpenSSL SSL connection owned by the native bridge. -/
def Conn : Type := ConnImpl.Pointed.type
instance : Nonempty Conn := ConnImpl.Pointed.property

private opaque ListenerImpl.Pointed : NonemptyType.{0}
/-- OpenSSL TLS listener (ALPN h2). -/
def Listener : Type := ListenerImpl.Pointed.type
instance : Nonempty Listener := ListenerImpl.Pointed.property

/-- Dial a TLS+ALPN `h2` connection.
    * `certPath`/`keyPath` present a client certificate (mTLS) when both are non-empty.
    * `caPath` non-empty loads that CA file; empty uses the system trust store.
    * `insecureSkipVerify = true` disables peer verify (dev/fixtures only). -/
@[extern "lean_grpc_tls_dial"]
opaque dial (host : @& String) (port : UInt16) (caPath : @& String) (serverName : @& String)
    (certPath : @& String := "") (keyPath : @& String := "")
    (insecureSkipVerify : Bool := false) : IO Conn

/-- Listen for TLS+ALPN `h2` connections presenting `certPath`/`keyPath` as the
    server identity. When `clientCaPath` is non-empty, clients are required to
    present a certificate verifiable against it (mTLS). -/
@[extern "lean_grpc_tls_listen"]
opaque listen (port : UInt16) (certPath : @& String) (keyPath : @& String)
    (clientCaPath : @& String := "") : IO Listener

@[extern "lean_grpc_tls_accept"]
opaque accept (l : @& Listener) : IO Conn

@[extern "lean_grpc_tls_send"]
opaque send (c : @& Conn) (bytes : @& ByteArray) : IO Unit

@[extern "lean_grpc_tls_recv"]
opaque recv (c : @& Conn) (maxBytes : @& Nat) : IO (Option ByteArray)

@[extern "lean_grpc_tls_close"]
opaque close (c : @& Conn) : IO Unit

/-- ByteTransport over an in-process TLS connection. -/
def transport (c : Conn) : H2.ByteTransport where
  send := fun b => send c b
  recv? := fun n => recv c n
  close := close c

@[extern "lean_grpc_rsa_sign_sha256"]
opaque rsaSignSha256 (pemKey : @& String) (message : @& ByteArray) : IO ByteArray

@[extern "lean_grpc_http_get"]
opaque httpGet (host : @& String) (port : UInt16) (path : @& String) (extraHeaders : @& String) :
    IO String

@[extern "lean_grpc_http_post"]
opaque httpPost (host : @& String) (port : UInt16) (path : @& String) (body : @& ByteArray)
    (contentType : @& String) : IO String

/-- HTTPS POST with peer+hostname verify (system CAs unless `caPath` set).
    `insecureSkipVerify` is for tests only. -/
@[extern "lean_grpc_https_post"]
opaque httpsPost (host : @& String) (port : UInt16) (path : @& String) (body : @& ByteArray)
    (contentType : @& String) (caPath : @& String := "") (insecureSkipVerify : Bool := false) :
    IO String

end Grpc.Native.Tls
