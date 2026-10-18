import Foundation

/// Frozen push wire and shared-storage identifiers used by the SDK, Drel NSE,
/// and server tests. Keep this file dependency-free; the NSE compiles it
/// directly without importing the full WebBridgeKit module.
public enum WBKPushWireContract {
    public static let ciphertextField = "ciphertext"
    public static let selfHostedEnvelopeField = "drelEnvelope"
    public static let selfHostedSchema = "drel.push-envelope.v1"

    public static let sharedAESDefaultsKey = "wbk.push-crypto.aes-key"
    public static let sharedAESFileSubpath = "push-crypto.key"
    public static let selfHostedPrivateKeyDefaultsKey = "drel.selfhosted-push.x25519-private-key"
    public static let selfHostedPrivateKeyFileSubpath = "drel-selfhosted-push.x25519-private-key"

    public static func selfHostedAssociatedData(
        messageID: String,
        createdAt: Int,
        expiresAt: Int
    ) -> Data {
        Data("\(selfHostedSchema)|\(messageID)|\(createdAt)|\(expiresAt)".utf8)
    }
}
