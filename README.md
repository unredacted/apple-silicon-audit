# apple-silicon-audit

An easy to use app to check your Apple Silicon security features.

Working app name: **Silicon Audit**. It reports which CPU-level security features the kernel on the exact device it runs on actually exposes, across every Apple platform, and separates what it *measured* from what Apple *documented*.

- [SPEC.md](SPEC.md) — implementation spec (v0.2, reviewed). Start here.
- [docs/spec-review.md](docs/spec-review.md) — the review of v0.1: every correction, the evidence, and the resulting edit.
- [docs/evidence/](docs/evidence/) — raw `sysctl` fixtures behind the review.

Status: spec complete, no code yet. Licensed under Apache-2.0.
