# Fuzz harness stubs

Future libFuzzer / AFL entry points for hostile-peer coverage:

| Target | Suggested entry | Notes |
|---|---|---|
| HTTP/2 frames | `H2.Frame.decode` / `H2.handleFrame` | After SETTINGS preface |
| HPACK | `Hpack.decodeHeaders` | Cap header list size first |
| Protobuf wire | `Proto.Wire.decodeFields` | Reject unknown wire types |
| zlib | `lean_grpc_gzip_decompress(..., max_out)` | Always pass max_out |

These stubs document the intended path; wire a corpus when CI ASAN + securityTests are green.
Do not gate merge on fuzz until a seed corpus exists.
