/-
Copyright (c) 2026 RileyBetts. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Grpc.Resolver

namespace Grpc.Balancer

inductive Policy where
  | pickFirst
  | roundRobin
  deriving BEq, Inhabited

structure State where
  policy : Policy := .pickFirst
  addrs : Array Resolver.Address := #[]
  next : Nat := 0
  deriving Inhabited

def create (policy : Policy) (addrs : Array Resolver.Address) : State :=
  { policy, addrs, next := 0 }

def pick (st : State) : Option Resolver.Address × State :=
  if st.addrs.isEmpty then (none, st)
  else
    match st.policy with
    | .pickFirst => (some st.addrs[0]!, st)
    | .roundRobin =>
      let i := st.next % st.addrs.size
      (some st.addrs[i]!, { st with next := st.next + 1 })

end Grpc.Balancer
