import CryptoKit
import Foundation

// Public-key-only verification, independent of the signing machine's Keychain.
guard CommandLine.arguments.count == 4,
      let key = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]) else {
    fatalError("Usage: verify-signature archive public-key-base64 signature-base64")
}
let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
guard publicKey.isValidSignature(signature, for: bytes) else {
    FileHandle.standardError.write(Data("Ed25519 signature verification failed\n".utf8))
    exit(1)
}
print("Ed25519 signature verified (\(bytes.count) bytes)")
