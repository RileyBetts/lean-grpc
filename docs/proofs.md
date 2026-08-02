# Formal proofs (pure codecs)

lean-grpc maintains a compile-time **`Proofs`** Lake library that machine-checks high-leverage pure properties of the wire stack. Theorems are checked when you run `lake build Proofs` (also a hard CI step). There is no runtime proof executable — success is “it typechecks.”

**Not a consumer API.** Applications depend on `Grpc` / `LeanGrpc`. `Proofs` is for maintainers and CI confidence.

## Scope

| In scope | Out of scope (for now) |
|---|---|
| Pure codecs and finite maps | FFI (`tls_ffi`, zlib helper) |
| Identity gRPC framing lemmas | Async TCP / connection state machines |
| BE integers, varints, HPACK integers | Full e2e gRPC sessions / interop peers |
| Frame type maps; kernel-checked frame roundtrips | Dynamic-table HPACK + Huffman bit-packing proofs |
| Metadata percent/base64/timeout fixtures | Flow-control / DoS policy as theorems |

Interop and security still rely on the existing runtime gates (`grpcTests`, h2spec, Go/Python/Rust interop, `securityTests`, ASAN). Proofs complement those; they do not replace them.

## How to run

```bash
lake build Proofs
```

CI builds `Proofs` alongside the unit-test executables (see `.github/workflows/ci.yml`).

## Layout

| Module | What is proved |
|---|---|
| `Proofs/Status.lean` | `StatusCode` ↔ `UInt32` bijection; out-of-range → `.unknown`; compression `name`/`parse?`; identity compress/decompress |
| `Proofs/BytesBE.lean` | Big-endian `u16` / `u24` / `u32` encode ↔ decode (∀); `Pool.pushBytes = (· ++ ·)` |
| `Proofs/Message.lean` | Identity frame shape `0 ‖ BE(len) ‖ payload`, size `5+\|p\|`, flag/length/payload byte lemmas; kernel-checked `encodeId` ↔ `decodeOne` fixtures |
| `Proofs/Wire.lean` | Varint encode for `v < 128`; kernel-checked varint roundtrips (incl. max 32/64-bit); `WireType.toNat` values |
| `Proofs/Frame.lean` | `FrameType` named/unknown maps; kernel-checked HTTP/2 frame encode ↔ decode fixtures |
| `Proofs/Hpack.lean` | RFC 7541 §5.1 integer fixtures; never-indexed `encodeHeaders` ↔ `decodeHeaders` |
| `Proofs/Metadata.lean` | Percent-encoding, base64, and `parseTimeoutMs` unit-table fixtures |

Root import: `Proofs.lean`.

## Proof styles

1. **General theorems** — quantified statements proved with Lean tactics (`cases`, `omega`, `bv_decide`, `simp`, …). Examples: `Proofs.Status.of_to`, `Proofs.BytesBE.read_u32Bytes`, `Proofs.Message.encodeId_size`.
2. **Kernel-checked fixtures** — closed terms decided by `native_decide` (computational reflection). These are still machine-checked proofs; they cover representative edge values (empty/max varint, ping frame, UTF-8 percent-encoding, …) where a full ∀ proof would need heavier refactoring or Mathlib.

No Mathlib dependency: proofs use Lean 4 stdlib + `Std.Tactic.BVDecide` only.

## Relation to runtime tests

| Runtime (`Tests/*Main`) | Proofs |
|---|---|
| IO `assert` / `throw` on mismatch | Compile-time propositions |
| Broad interop / stress | Narrow pure invariants |
| Catches peer/FFI regressions | Catches codec algebraic mistakes |

When changing a pure codec covered here, keep **both** `lake build Proofs` and the matching unit exe green.

## Extending

Prefer new lemmas under `Proofs/` over sprinkling `theorem` into production modules. Good next targets (still pure):

- General `Message.encodeId` ↔ `decodeOne` (beyond fixtures)
- General `Frame.encode` ↔ `decode` under `payload.size < 2^24`
- Inductive protobuf varint roundtrip for all `UInt64`
- `StatusDetails` code agree/contradict lemmas

Avoid claiming proofs of TLS, ADC, or full connection correctness until those layers have pure, inductive specs.
