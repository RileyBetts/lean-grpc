## Why

## How to test

- [ ] `lake build` (or relevant targets)
- [ ] Minimum test binaries from CONTRIBUTING.md (if touching libraries)
- [ ] h2spec / interop / securityTests as applicable

## Docs

- [ ] Updated `docs/` (api-reference / protocol-mapping / conformance) if public API or wire behaviour changed
- [ ] If a curated site page is affected, note that [rileybetts.ai/oss/lean-grpc](https://rileybetts.ai/oss/lean-grpc) needs a sync

## Checklist

- [ ] No unrelated refactors
- [ ] No secrets or generated certs committed
- [ ] Security-sensitive changes follow CONTRIBUTING.md / SECURITY.md
