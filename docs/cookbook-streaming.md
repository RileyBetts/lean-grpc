<!--
Copyright © 2026, Riley Betts Ltd (rileybetts.ai)
-->

# Cookbook: streaming RPCs

lean-grpc exposes both low-level duplex (`openStream`) and batch helpers for the three streaming shapes.

## Client helpers

| Helper | Shape |
|---|---|
| `Grpc.Channel.serverStream` | one request → many responses |
| `Grpc.Channel.clientStream` | many requests → one response |
| `Grpc.Channel.bidiStream` | many → many (send all, then recv all) |
| `Grpc.Channel.openStream` | interactive `StreamWriter` / `StreamReader` |

```lean
-- Server streaming
let (msgs, st) ← Grpc.Channel.serverStream ch "svc" "List" reqBytes
-- Client streaming
let res ← Grpc.Channel.clientStream ch "svc" "Record" reqArray
-- Bidi (batch)
let (echo, st) ← Grpc.Channel.bidiStream ch "svc" "Chat" reqArray
```

Interactive duplex (send/recv interleaved):

```lean
let stream ← Grpc.Channel.openStream ch "svc" "Chat"
Grpc.Stream.StreamWriter.send stream.writer msg1
match ← Grpc.Stream.StreamReader.recv? stream.reader with
| some raw => pure ()
| none => pure ()
Grpc.Stream.StreamWriter.halfClose stream.writer
let rest ← Grpc.Stream.StreamReader.recvAll stream.reader
```

## Server helpers

Raw `ByteArray` registers still work. Prefer typed adapters when you have codecs:

```lean
s := Grpc.Server.registerServerStreamTyped s "svc" "List"
  Req.decode Resp.encode fun req => do
    pure (#[resp1, resp2], .ok)

s := Grpc.Server.registerClientStreamTyped s "svc" "Record"
  Req.decode Resp.encode fun reqs => do
    pure (aggregate reqs, .ok)

s := Grpc.Server.registerBidiTyped s "svc" "Chat"
  Req.decode Resp.encode fun reqs => do
    pure (reqs, .ok)  -- echo
```

## Worked example

`Examples/RouteGuide/` — unary + all three streaming shapes on both sides.

## Limitations

- Server handlers are still **batch** (arrays), not callback-driven writers.
- True ping-pong duplex on the server is incremental only for bidi DATA chunks (see `Grpc.Server.handlerFor`).
- Descriptor codegen emits typed **client** streaming stubs; streaming **server** register helpers are the `*Typed` APIs above.
