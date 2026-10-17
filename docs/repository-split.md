# WebBridgeKit-Framework Repository Split

Date: 2026-10-17

This repository is the reusable WebBridgeKit SDK split from the historical
WebBridgeKit monorepo as described in `docs/adr/0006-split-drel-product-repository.md`.

The split source revision in the legacy local checkout was:

```text
e68423d9 chore(repo): add license and media ignore rules
```

This repository intentionally retains the frozen `drel_`-prefixed v1 wire formats documented in ADR-0006 because deployed servers, notification extensions, and template pages depend on them. Product-specific Drel application code, server code, release tooling, and App Store assets live in the separate Drel repository.
