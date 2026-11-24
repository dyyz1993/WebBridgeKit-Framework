# WebBridgeKit Framework (`WebBridgeKit-Framework`)

iOS 原生增强 PWA 运行时底层框架 SDK（`WebBridgeKit`）与最小宿主接入模板（`AppTemplate`）。

## 1. 仓库定位与边界

本工程是从原 `WebBridgeKit` 单体仓库按照 `ADR-0002` 与 `ADR-0006` 规范拆分出的**独立底层框架工程**，仅承载跨宿主通用的 SDK 能力与最小集成脚手架：

- **`Sources/`（WebBridgeKit SDK 核心）**：包含 6 大核心引擎（`Bridge`、`Cache`、`Message`、`AI`、`Theme`、`Skills`）、2 大基础设施（`WebSocket`、`CommandParser`）、41 个原生能力 Handler、通用 HTML App 运行时（`Runtime/`）及服务定位层（`Services/`）。
- **`Resources/`**：内置 `WebBridge.js` 桥接脚本、调试辅助脚本及 `PrivacyInfo.xcprivacy` 隐私清单。
- **`AppTemplate/`（最小宿主起点）**：演示如何安全初始化并接入 `WebBridgeKit` SDK 的最小宿主工程，不包含任何测试硬编码凭据、不默认自启后台调试服务，亦不耦合上层业务 UI。
- **`Tests/`（单元测试矩阵）**：包含 19 个单元测试 Target（`BridgeTests`、`CacheTests`、`MessageTests`、`HandlerTests`、`CoreTests`、`ModelsTests` 等共 168 个测试文件）。

> 上层完整产品应用（Target 为 `Drel`，源码目录为 `SuperApp/`）、通知服务扩展（`NotificationServiceExtension`）、UI 自动化测试（`DrelUITests`）及后端服务（`Server/`）已独立拆分至同级 [Drel 仓库](https://github.com/dyyz1993/Drel)。两个开发仓库目前均为私有仓库，需要相应 GitHub 访问权限；旧公开 `WebBridgeKit` 仓库仅保留历史代码和公开技能分发。

## 2. 宿主注入与解耦契约（Phase 1 解耦落地）

为确保底层 SDK 对任意第三方宿主保持品牌中立与配置隔离，框架层提供以下启动注入点：

1. **容器构建模式注入**：`WebBridgeHostCapabilityPolicy.containerOnlyOverride`
   （默认 `nil`，框架默认开启完整 JSBridge 能力；上层容器型宿主可在启动时
   注入 `true` 禁用 Bridge 注入）。
2. **网关信任锚点注入**：宿主创建 `HTMLAppGatewayRegistry(officialGateway:)`
   时传入自身的官方网关配置与 Ed25519 公钥；SDK 不内置任何产品默认网关。
3. **App Group 与钥匙串命名空间注入**：
   - `PushCipher.configure(appGroup:keychainService:)`
   - `SelfHostedPushCrypto.configure(appGroup:)`

## 3. 快速开始与集成方式

### 方式 A：作为独立框架工程开发与运行单测

```bash
xcodegen generate
pod install

# 编译框架与最小宿主模板
xcodebuild build -workspace WebBridgeKit.xcworkspace -scheme WebBridgeKit -sdk iphonesimulator -arch arm64 CODE_SIGNING_ALLOWED=NO
xcodebuild build -workspace WebBridgeKit.xcworkspace -scheme AppTemplate -sdk iphonesimulator -arch arm64 CODE_SIGNING_ALLOWED=NO

# 运行框架边界与架构/设计门禁
bash tools/verify-deliverable-boundaries.sh
bash tools/architecture-lint.sh --ci
bash tools/design-lint.sh --ci
bash tools/ci-lint.sh
```

### 方式 B：CocoaPods 接入（无需克隆本仓库）

在你的应用工程 `Podfile` 中按 tag 引入，CocoaPods 会自动拉取源码：

```ruby
pod 'WebBridgeKit', :git => 'https://github.com/dyyz1993/WebBridgeKit-Framework.git', :tag => '1.4.0'
```

与上层应用 `Drel` 协同开发、需要同时修改 SDK 时，改用本地路径：

```ruby
pod 'WebBridgeKit', :path => ENV.fetch('WBK_FRAMEWORK_PATH', '../WebBridgeKit-Framework')
```

### 方式 C：Swift Package Manager 接入

本工程根目录提供 `Package.swift`，暴露 `WebBridgeKit` 与 `WBKMessage` 两个 Library Product。最低支持 iOS 15 / Swift 5.9。

**Xcode 图形界面**：File → Add Package Dependencies… → 搜索框输入 `https://github.com/dyyz1993/WebBridgeKit-Framework.git` → Dependency Rule 选「Up to Next Major Version」并填 `1.4.0` → Add Package → 勾选 `WebBridgeKit`。

**或在 `Package.swift` 中声明**：

```swift
dependencies: [
    .package(url: "https://github.com/dyyz1993/WebBridgeKit-Framework.git", from: "1.4.0")
]
```

然后在 target 的 `dependencies` 中加入 `.product(name: "WebBridgeKit", package: "WebBridgeKit-Framework")`。

## 4. 开发规范与跨层协作指南

- 本仓库的开发规范与代码质量门禁：`CONTRIBUTING.md`、`AGENTS.md`
- 《应用层遇到底层框架问题的标准排查与处理 SOP》：见上层应用仓库 [Drel 的协作指南](https://github.com/dyyz1993/Drel/blob/main/docs/DEVELOPMENT_AND_COLLABORATION_GUIDE.md)
