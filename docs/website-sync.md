# Website docs sync

Curated lean-grpc documentation is published at
[rileybetts.ai/oss/lean-grpc](https://rileybetts.ai/oss/lean-grpc).

## Source of truth

| Location | Role |
|---|---|
| This repository (`docs/`, `SECURITY.md`, `ROADMAP.md`, …) | Source of truth |
| `rileybetts_website` content package + Jinja templates | Curated hosted mirror |

Not every in-repo doc is hosted (security-review narrative, stress demos, interop READMEs stay GitHub-only).

## Sync rule

When you change a **curated** guide in lean-grpc, update the website in the **same release window**:

1. Edit the markdown here.
2. In the website repo, run:

   ```bash
   python3 scripts/promote_oss_lean_grpc.py --lean-grpc /path/to/lean-grpc
   ```

3. Review the regenerated HTML under
   `rileybetts_website/templates/includes/oss/lean-grpc/`.
4. Deploy website `development` → staging, then `main` → production.

Landing and security posture pages are authored in the website content package
(`content/package/sections/oss-lean-grpc/landing.md`, `security.md`) and should
stay aligned with `README.md` / `SECURITY.md` here.

## Release sequencing (docs + Reservoir)

1. Polish / merge lean-grpc docs on `development` → `main`.
2. Promote website pages; stage then production deploy.
3. Ensure the GitHub repo is public, Apache-2.0 detected, Security Advisories on, ≥2 stars.
4. Maintainer tags `v0.5.0` manually (see [packaging.md](packaging.md)).
5. Wait for Reservoir’s daily crawl; verify the package page and homepage link.
6. Prefer bare `require «lean-grpc»` in README/site copy once indexed.

See also [packaging.md](packaging.md) and [CONTRIBUTING.md](../CONTRIBUTING.md).
