# Python interop helpers

Uses `grpcio` + official `grpc.testing` protos to exercise lean-grpc **without Go**.

```bash
# Python client → Lean server
./scripts/run-python-to-lean.sh

# Lean client → Python server
GRPC_PORT=10001 ./scripts/interop-lean-python.sh
```

Requires a local venv at `.venv-interop` (created by the scripts).
