# WebBridgeKit Framework (`WebBridgeKit-Framework`)

[中文](README.md) | English

The native-enhanced PWA runtime SDK for iOS (`WebBridgeKit`) and a minimal host
template (`AppTemplate`).

## 1. What this repository is

This is the standalone framework repository, split out of the original
`WebBridgeKit` monorepo per `ADR-0002` and `ADR-0006`. It holds only the
host-agnostic SDK and a minimal integration scaffold:

- **`Sources/`** (the SDK): six core engines (`Bridge`, `Cache`, `Message`,
  `AI`, `Theme`, `Skills`), two infrastructure layers (`WebSocket`,
  `CommandParser`), and the native handlers.
- **`Resources/`**: the bundled `WebBridge.js` bridge script, debugging
  helpers and the `PrivacyInfo.xcprivacy` privacy manifest.
- **`AppTemplate/`** (minimal host): shows how to initialise and adopt the SDK
  safely. It has no test credentials, starts no background debug services and
  carries no product UI.
- **`Tests/`**: the unit test matrix, one target per engine (`BridgeTests`,
  `CacheTests`, `MessageTests`, `HandlerTests`, `CoreTests`, `ModelsTests`, ...).

> The full product app (target `Drel`, sources in `SuperApp/`), the
> notification extension, the UI automation tests and the backend live in the
> sibling [Drel repository](https://github.com/dyyz1993/Drel).

## 2. Host injection and decoupling contract

The SDK stays brand-neutral and configuration-isolated for any third-party
host. It exposes these startup injection points:

1. **Container build mode**: `WebBridgeHostCapabilityPolicy.containerOnlyOverride`.
   It defaults to `nil`, which keeps the full JSBridge enabled. A container-style
   host injects `true` at launch to disable Bridge injection.
2. **Gateway trust anchor**: the host passes its own official gateway
   configuration and Ed25519 public key when it creates
   `HTMLAppGatewayRegistry(officialGateway:)`. The SDK ships no default product
   gateway.
3. **App Group and keychain namespace**:
   - `PushCipher.configure(appGroup:keychainService:)`
   - `SelfHostedPushCrypto.configure(appGroup:)`

## 3. Quick start and integration

### Option A: develop the framework and run its unit tests

```bash
xcodegen generate
pod install

# Build the framework and the minimal host
xcodebuild build -workspace WebBridgeKit.xcworkspace -scheme WebBridgeKit -sdk iphonesimulator -arch arm64 CODE_SIGNING_ALLOWED=NO
xcodebuild build -workspace WebBridgeKit.xcworkspace -scheme AppTemplate -sdk iphonesimulator -arch arm64 CODE_SIGNING_ALLOWED=NO

# Run the boundary, architecture and design gates
bash tools/verify-deliverable-boundaries.sh
bash tools/architecture-lint.sh --ci
bash tools/design-lint.sh --ci
bash tools/ci-lint.sh
```

### Option B: CocoaPods (no clone needed)

Reference a tag in your app's `Podfile` and CocoaPods fetches the sources:

```ruby
pod 'WebBridgeKit', :git => 'https://github.com/dyyz1993/WebBridgeKit-Framework.git', :tag => '1.4.0'
```

When you develop the SDK together with the `Drel` app, use a local path instead:

```ruby
pod 'WebBridgeKit', :path => ENV.fetch('WBK_FRAMEWORK_PATH', '../WebBridgeKit-Framework')
```

### Option C: Swift Package Manager

The `Package.swift` at the repository root exposes two library products,
`WebBridgeKit` and `WBKMessage`. Minimum requirements: iOS 15 / Swift 5.9.

**In Xcode**: File → Add Package Dependencies… → enter
`https://github.com/dyyz1993/WebBridgeKit-Framework.git` → choose
"Up to Next Major Version" and enter `1.4.0` → Add Package → tick `WebBridgeKit`.

**Or declare it in your `Package.swift`**:

```swift
dependencies: [
    .package(url: "https://github.com/dyyz1993/WebBridgeKit-Framework.git", from: "1.4.0")
]
```

Then add `.product(name: "WebBridgeKit", package: "WebBridgeKit-Framework")` to
your target's `dependencies`.

### Option D: prebuilt xcframework (optional)

`WebBridgeKit` is a **dynamic** framework whose public interface
(`.swiftinterface`) directly `import`s the third-party modules from the
podspec (`RxSwift`, `RealmSwift`, `SnapKit`, ...). A binary build therefore does
**not** bundle those dependencies: the consumer has to link the same modules at
the same versions, or a host app that also uses them gets duplicate symbols.

```bash
bash tools/build-xcframework.sh            # writes to build/xcframework
```

The script archives a device and a simulator slice, assembles
`WebBridgeKit.xcframework` and writes a `MANIFEST.json` recording the version,
the Xcode it was built with and the modules the consumer must link. The
`.swiftinterface` is tied to that Xcode version, so rebuild after upgrading
Xcode.

For most users **option B or C (source dependency) is simpler**: nothing is tied
to a compiler version and no dependencies have to be aligned by hand. Choose
option D only when consumers must not compile the SDK sources.

## 4. Development and collaboration

- Development rules and quality gates for this repository: `CONTRIBUTING.md`, `AGENTS.md` (Chinese)
- The SOP for handling framework issues from the app layer: the
  [Drel collaboration guide](https://github.com/dyyz1993/Drel/blob/main/docs/DEVELOPMENT_AND_COLLABORATION_GUIDE.md) (Chinese)

## License

[MIT](LICENSE)
