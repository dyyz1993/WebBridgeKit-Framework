//
//  HTMLAppBridgeCapabilityPolicy.swift
//  WebBridgeKit
//

import Foundation

/// Adopted by native handlers that keep hardware or sensor work alive after
/// the original JavaScript request has completed.
public protocol HTMLAppCapabilityRevocationHandling: AnyObject {
    func htmlAppCapabilityDidRevoke()
}

/// The single mapping between JavaScript Bridge actions and managed-PWA
/// capabilities. Actions not listed here remain available to ordinary web
/// pages and do not receive access to protected native data or hardware.
public enum HTMLAppBridgeCapabilityPolicy {
    public static func controlledAction(for action: String) -> HTMLAppControlledAction? {
        switch action {
        case "haptic": return .haptic
        case "vibrate": return .vibrate
        case "share": return .share
        case "fullscreen": return .fullscreen
        case "clipboard": return .clipboard
        case "getLocation": return .getLocation
        case "addToHomeScreen": return .addToHomeScreen
        case "sensors": return .sensors
        default: return nil
        }
    }

    public static func capability(for action: String, body: [String: Any]) -> HTMLAppCapability? {
        switch action {
        case "haptic", "vibrate", "fullscreen": return .displayStatus
        case "bluetooth": return .bluetooth
        case "camera", "videoStream": return .camera
        case "clipboard": return .clipboard
        case "contacts": return .contacts
        case "addToHomeScreen": return .homeScreen
        // gesture/layout/screen：纯容器交互，不涉及用户隐私，免授权
        case "gesture", "layout", "screen": return nil
        case "file": return .fileImport
        case "getLocation": return .location
        case "audioLevel", "speech": return .microphone
        // mirroring：只读投屏状态查询，不涉及用户隐私，免授权
        case "mirroring": return nil
        case "photo": return .photoLibrary
        case "scan": return .scan
        case "sensors": return .motion
        case "share": return .share
        case "showNotification": return .notification
        case "systemExtra":
            switch parameters(in: body)["action"] as? String {
            case "authenticate": return .biometrics
            case "setBadge": return .notification
            case "setTorch": return .camera
            default: return .deviceControl
            }
        case "requestPermission":
            let type = parameters(in: body)["type"] as? String
                ?? parameters(in: body)["permission"] as? String
            return type.flatMap(HTMLAppCapability.init(rawValue:))
        case "media":
            let operation = parameters(in: body)["action"] as? String
            switch operation {
            case "saveImage": return .photoLibrary
            case "saveFile", "uploadFile": return .fileExport
            default: return nil
            }
        default:
            return nil
        }
    }

    public static func capability(for action: HTMLAppControlledAction) -> HTMLAppCapability {
        switch action {
        case .haptic, .vibrate: return .displayStatus
        case .share: return .share
        case .fullscreen: return .displayStatus
        case .clipboard: return .clipboard
        case .getLocation: return .location
        case .addToHomeScreen: return .homeScreen
        case .sensors: return .motion
        }
    }

    /// Grant-based capabilities require explicit reusable consent so a signed
    /// declaration cannot become blanket access to user data.
    public static func isGrantBasedAction(_ action: HTMLAppControlledAction) -> Bool {
        switch action {
        case .clipboard, .getLocation: return true
        // sensors：原始运动数据无系统隐私语义，与展示类动作同级，走会话声明即可
        case .haptic, .vibrate, .share, .fullscreen, .addToHomeScreen, .sensors: return false
        }
    }

    private static func parameters(in body: [String: Any]) -> [String: Any] {
        body["params"] as? [String: Any] ?? body
    }
}
