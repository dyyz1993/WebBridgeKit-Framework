# Contributing to WebBridgeKit (Framework)

This repository is the **standalone WebBridgeKit framework repo** (`WebBridgeKit-Framework`),
split out of the original `WebBridgeKit` monorepo per ADR-0002 / ADR-0006
(see `docs/repository-split.md`). It contains only the reusable SDK, the minimal
host template, and the SDK unit-test matrix.

**This repository is public and MIT licensed.** Clone it over HTTPS without any
GitHub access, and contribute through a fork and a pull request against `main`;
see "Pull Request Process" below.

**The product app is a sibling repo, not this repo.** `Drel`
(`github.com/dyyz1993/Drel`, checked out side-by-side with this repo) owns the
`Drel` product target (source directory `SuperApp/`), the `Server/` backend,
`NotificationServiceExtension`, and `SuperAppUITests/`. Do **not** look for a
`SuperApp` scheme here — this repo has none. Some legacy scripts still mention
`SuperApp` (see "Known monorepo leftovers" below); the gates listed in this
guide are the ones that work against the framework alone.

## Development Environment Setup

### Prerequisites

| Tool | Install | Notes |
|------|---------|-------|
| Xcode | Mac App Store | iOS 15+ SDK |
| CocoaPods | `sudo gem install cocoapods` | Workspace dependencies |
| XcodeGen | `brew install xcodegen` | Generates `WebBridgeKit.xcodeproj` from `project.yml` |
| SwiftLint | `brew install swiftlint` | `.swiftlint.yml` |
| xcpretty | `gem install xcpretty --no-document` | Used by `scripts/bootstrap-dev.sh` |

`bash scripts/bootstrap-dev.sh --install-tools` attempts to install missing
tools via Homebrew/gem automatically.

### Setup

```bash
git clone git@github.com:dyyz1993/WebBridgeKit-Framework.git
cd WebBridgeKit-Framework
bash scripts/bootstrap-dev.sh --no-services
open WebBridgeKit.xcworkspace
```

`scripts/bootstrap-dev.sh` installs git hooks, runs `xcodegen generate`,
runs `pod install`, verifies the toolchain, and (unless `--no-services`) starts
local services. Useful options:

```bash
bash scripts/bootstrap-dev.sh --no-services        # skip local services
bash scripts/bootstrap-dev.sh --no-hooks           # skip git hooks
bash scripts/bootstrap-dev.sh --install-tools      # auto-install missing tools
```

### Project Generation

- `WebBridgeKit.xcodeproj/` is generated and ignored. **`project.yml` is the
  source of truth.**
- After changing `project.yml`, run `xcodegen generate && pod install` before
  any build or verification gate. Skipping `pod install` breaks resolution of
  CocoaPods modules (SnapKit, RxSwift/RxCocoa, Moya, SwiftSoup, RealmSwift,
  ZIPFoundation).

## How to Build

```bash
xcodegen generate
pod install

# Framework (SDK)
xcodebuild build \
  -workspace WebBridgeKit.xcworkspace \
  -scheme WebBridgeKit \
  -sdk iphonesimulator \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO

# Minimal host template
xcodebuild build \
  -workspace WebBridgeKit.xcworkspace \
  -scheme AppTemplate \
  -sdk iphonesimulator \
  -arch arm64 \
  CODE_SIGNING_ALLOWED=NO
```

These are exactly the two build steps CI runs (`.github/workflows/ci.yml`).

### Known monorepo leftovers

The following still reference the old monorepo `SuperApp` scheme/target and
will not work against this repo alone; use the gates and commands in this
guide instead until they are cleaned up:

- `scripts/verify-build.sh` (builds `-scheme SuperApp`)
- `./run_tests.sh` (`smoke`/`test` subcommands route through it)
- `tools/run-cache-regression.sh` UI portion (runs `SuperAppUITests/CacheDashboardTests`)

## Testing Requirements

Tests are unit tests against the SDK schemes only. Each module has its own
Xcode scheme generated from `project.yml`.

```bash
# Single module (example: Cache)
xcodebuild test \
  -workspace WebBridgeKit.xcworkspace \
  -scheme CacheTests \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO

# Handler matrix (split for CI stability)
xcodebuild test -workspace WebBridgeKit.xcworkspace \
  -scheme HandlerTests-Part1 -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO
```

CI groups the same schemes into four matrix jobs (`.github/workflows/ci.yml`,
`unit-tests`): **CoreA** (CacheTests, BridgeTests, CoreTests), **CoreB**
(ModelsTests, UtilsTests, ServicesTests), **Handlers** (HandlerTests-Part1,
HandlerTests-Part2, CommandParserTests, WebSocketTests, SkillsTests), and
**Modules** (MessageTests, AITests, InfrastructureTests, BaseTests,
ExtensionsTests, ManagersTests, ViewModelTests, WebBridgeKitTests).
`ThemeTests` also exists as a local scheme.

- **All new SDK code must have tests.** Test files live in `Tests/<Module>Tests/`
  organized by module; naming: `XxxTests.swift`.
- Adding a new module: create the source target **and** the test target in
  `project.yml`, then `xcodegen generate && pod install`.

### Test Directory Structure

```
Tests/
├── AITests/
├── BaseTests/
├── BridgeTests/
├── CacheDashboard/
├── CacheTests/
├── CommandParserTests/
├── CoreTests/
├── ExtensionsTests/
├── HandlerTests/
├── Infrastructure/
├── ManagersTests/
├── MessageTests/
├── ModelsTests/
├── ServicesTests/
├── SkillsTests/
├── ThemeTests/
├── UtilsTests/
├── ViewModelTests/
├── WebBridgeKitTests/
├── WebSocketTests/
└── e2e/
```

## Local Services (Optional)

SDK unit tests do not require services. Cache/offline fixture verification
does. `scripts/services.sh` starts:

| Service | Port | Source in the split setup |
|---------|------|---------------------------|
| Swift backend (`WebBridgeServer`) | 8080 | **Sibling `Drel` repo** — point at it with `DREL_APP_ROOT=/path/to/Drel` |
| Test HTTP server (repo root + `test_resources/`) | 8081 | This repo |
| Prototype HTML server (`docs/prototype/`) | 8083 | This repo (or `Drel` when `DREL_APP_ROOT` is set) |

```bash
export DREL_APP_ROOT=/path/to/Drel   # needed only for the :8080 backend
bash scripts/services.sh start       # or stop / status / verify / logs
bash tools/verify-strong-offline-package.sh   # offline-package fixture vs :8081
```

## Code Style

We use [SwiftLint](https://github.com/realm/SwiftLint) with `.swiftlint.yml`.
Notable configuration:

- **Line length** warning 300 / error 500; **file length** warning 600 / error 1000.
- **Opt-in rules**: `empty_count`, `closure_spacing`, `explicit_init`,
  `overridden_super_call`, `private_outlet`, `prohibited_super_call`,
  `vertical_parameter_alignment`, `first_where`.
- **Custom design rules** (warnings):
  - No hardcoded `UIColor(red:...)` or `.systemBlue`-style system colors —
    use `ThemeTokens.Color.*` (auto light/dark).
  - No static `ThemeTokens.Colors.Light/Dark.*` tokens (no dark-mode support).
  - Prefer `LucideIcon.*.image()` over SF Symbols (`UIImage(systemName:)`).
  - Prefer `ThemeTokens.Typography.*` / Dynamic Type over fixed `UIFont.systemFont(ofSize:)`.

Design tokens live in `docs/design-tokens.json` (single source of truth) and
sync into Swift via `bash tools/sync-tokens.sh`.

### Lint

```bash
swiftlint --quiet
bash tools/ci-lint.sh   # full design-system wrapper: colors, icons, fonts,
                        # token JSON, touch targets, deliverable boundaries
```

CI runs SwiftLint and the lint workflows (`.github/workflows/architecture-lint.yml`,
`.github/workflows/design-lint.yml`) on every push. Fix warnings before pushing.

## Verification Gates

Run the gates relevant to your change before opening a PR:

| Gate | Command |
|------|---------|
| Deliverable boundaries (SDK vs template vs product app) | `bash tools/verify-deliverable-boundaries.sh` |
| AppTemplate readiness | `bash tools/run-template-gate.sh` |
| Architecture lint | `bash tools/architecture-lint.sh --ci` |
| Design lint | `bash tools/design-lint.sh --ci` |
| Cached HTML fixtures | `bash tools/validate-cache-html.sh` |
| Offline-package fixture | `bash tools/verify-strong-offline-package.sh` |

Boundary rules enforced by `verify-deliverable-boundaries.sh`: SDK sources in
`Sources/` must not import product code or product-only pods; this repo must
not contain `SuperApp/`, `NotificationServiceExtension/`, or `Server/` — those
belong to the `Drel` sibling repo.

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]
```

**Types:** `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `ci`, `perf`

**Examples:**

```
feat(bridge): gate managed actions by gesture
fix(cache): resolve manifest race condition
test(message): add channel pipeline tests
docs: update integration guide
```

## Pull Request Process

1. Fork the repository, branch from `main` (e.g. `feat/bridge-xyz`) and push
   the branch to your fork. Maintainers can work on a branch in this
   repository instead.
2. Write/update unit tests for all SDK changes.
3. Run `swiftlint --quiet` and the relevant verification gates locally.
4. Open a PR against `main`. PR titles follow the commit format:
   `feat(scope): description`.
5. CI must pass: SwiftLint, Build (WebBridgeKit + AppTemplate + boundary
   check), the unit-test matrix, and the architecture/design lint workflows.
   Continuous integration runs on the maintainers' own machines. The jobs for
   a pull request from a fork are skipped, even after a maintainer approves the
   run, so run the checks locally and paste the results into the pull request;
   a maintainer will run them from a branch inside this repository.
6. At least one maintainer review before merge.

## Architecture Overview

```
┌──────────────────────────────────────────────────┐
│  Host apps                                        │
│  Drel product app (sibling repo) · your own app   │
├──────────────────────────────────────────────────┤
│  AppTemplate                                      │
│  Minimal host scaffold (AppDelegate/Root/TabBar)  │
├──────────────────────────────────────────────────┤
│  WebBridgeKit SDK                                 │
│  ┌──────┬──────┬───────┬────┬──────┬──────┐      │
│  │Bridge│Cache │Message│ AI │Theme │Skills│      │
│  └──────┴──────┴───────┴────┴──────┴──────┘      │
│  WebSocket · CommandParser · 41 Handlers          │
│  Runtime/ (HTML app runtime) · Services/          │
└──────────────────────────────────────────────────┘
```

### Engines

| Engine | Core Classes | Purpose |
|--------|--------------|---------|
| Bridge | `WebJavaScriptBridge` | JS ↔ Native bidirectional communication |
| Cache | `CacheManager` / `ManifestCacheManager` | 3-tier cache (memory / disk / manifest offline) |
| Message | `MessageEngine` | Push notifications, processor pipeline, routing |
| AI | `AIHTTPServer` / `AIRouter` | Local HTTP API + MCP tool protocol |
| Theme | `ThemeManager` | Design-token theming, light/dark |
| Skills | `SkillRegistry` | Pluggable skill modules |

## Directory Structure

```
WebBridgeKit-Framework/
├── Sources/                  # SDK source (engines, handlers, runtime, services)
├── Resources/                # WebBridge.js, js/ debug scripts, PrivacyInfo.xcprivacy
├── AppTemplate/              # Minimal host template app
├── Tests/                    # Per-module unit test targets
├── tools/                    # Verification gates and linters
├── scripts/                  # bootstrap-dev.sh, services.sh, dev utilities
├── test_resources/           # Local fixtures for cache/offline verification
├── docs/                     # ADRs, architecture, repository-split, design tokens
├── Package.swift             # SPM products: WebBridgeKit, WBKMessage
├── project.yml               # XcodeGen project spec (source of truth)
├── Podfile                   # CocoaPods dependencies
├── WebBridgeKit.podspec      # CocoaPods spec (source git + tag)
└── .swiftlint.yml            # SwiftLint configuration
```

## Consuming the SDK (from `Drel` or another host)

CocoaPods (development, local path — see README):

```ruby
pod 'WebBridgeKit', :path => ENV.fetch('WBK_FRAMEWORK_PATH', '../WebBridgeKit-Framework')
```

CocoaPods (a tagged release):

```ruby
pod 'WebBridgeKit', :git => 'https://github.com/dyyz1993/WebBridgeKit-Framework.git', :tag => '1.4.0'
```

Swift Package Manager: this repo's `Package.swift` exposes the `WebBridgeKit`
and `WBKMessage` library products.

`1.4.0` is published and resolves anonymously. Drel does not depend on the tag:
its `framework-revision.txt` pins a commit of this repository's `main` branch
and its build checks that commit out, so moving `main` does not break Drel
until that pin is moved on purpose.

## Further Reading

- `README.md` — repo positioning, host-injection contracts, integration modes
- `docs/repository-split.md` + `docs/adr/` — the split decision and boundaries
- `docs/ARCHITECTURE.md` — SDK architecture details
