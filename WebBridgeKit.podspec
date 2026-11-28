Pod::Spec.new do |s|
  s.name             = 'WebBridgeKit'
  s.version          = '1.4.2'
  s.summary          = 'Reusable iOS Native-Enhanced PWA Runtime SDK (Bridge, Cache, Message, AI, Theme, Skills).'
  s.description      = <<-DESC
    WebBridgeKit provides a unified JS-to-Native Bridge (41 handlers), 3-tier offline/manifest cache engine,
    actor-based push/message routing engine, WebSocket JSON-RPC 2.0 client, AI MCP debug interface,
    and design token theme engine for iOS host applications.
  DESC
  s.homepage         = 'https://github.com/dyyz1993/WebBridgeKit-Framework'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'WebBridgeKit Team' => 'dev@webbridgekit.org' }
  s.source           = { :git => 'https://github.com/dyyz1993/WebBridgeKit-Framework.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_version = '5.9'
  s.static_framework = true

  s.source_files = 'Sources/**/*.swift'
  s.resource_bundles = {
    'WebBridgeKitResources' => [
      'Resources/WebBridge.js',
      'Resources/js/*.js',
      'Sources/Theme/icons.xcassets'
    ],
    'WebBridgeKitPrivacy' => ['Resources/PrivacyInfo.xcprivacy']
  }

  s.dependency 'SnapKit'
  s.dependency 'RxSwift', '~> 6.0'
  s.dependency 'RxCocoa', '~> 6.0'
  s.dependency 'RxDataSources', '~> 5.0'
  s.dependency 'Moya/RxSwift', '~> 15.0'
  s.dependency 'SwiftSoup', '~> 2.6'
  s.dependency 'RealmSwift', '~> 10.42'
  s.dependency 'ZIPFoundation', '~> 0.9'
end
