/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.ServiceConfig
import Grpc.Status

namespace Grpc.Retry

def shouldRetry (policy : ServiceConfig.RetryPolicy) (code : StatusCode) (attempt : Nat) : Bool :=
  attempt + 1 < policy.maxAttempts &&
    policy.retryableStatusCodes.any (· == code.toUInt32)

/-- Exponential backoff delay in ms for the next attempt. -/
def backoffMs (policy : ServiceConfig.RetryPolicy) (attempt : Nat) : Nat :=
  Id.run do
    let mut d := policy.initialBackoffMs
    for _ in [:attempt] do
      d := min policy.maxBackoffMs (d * policy.backoffMultiplier)
    return d

end Grpc.Retry
