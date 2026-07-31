/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Bytes
import Hpack
import H2
import Proto
import Grpc.Status
import Grpc.Compression
import Grpc.Message
import Grpc.Metadata
import Grpc.Server
import Grpc.Client
import Grpc.Stream
import Grpc.Native.Tls
import Grpc.Tls
import Grpc.Credentials
import Grpc.Resolver
import Grpc.Balancer
import Grpc.ServiceConfig
import Grpc.Retry
import Grpc.Channel
import Grpc.Health
import Grpc.Reflection
import Grpc.Channelz
import Grpc.Adc
import Grpc.Gcp
import Grpc.Jwt
import Grpc.Orca
import Grpc.Xds
import Grpc.Xds.Discovery
import Grpc.XdsAds

namespace Grpc
def version : String := "0.4.0"
end Grpc
