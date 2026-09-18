import json
import pathlib
import subprocess
import tempfile
import unittest


class SignatureTests(unittest.TestCase):
    def test_public_key_verification_rejects_same_length_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            archive = root / "fixture.bin"
            archive.write_bytes(b"synthetic update")
            signer = root / "sign-fixture.swift"
            signer.write_text('''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let output = ["publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
              "signature": try key.signature(for: data).base64EncodedString()]
print(String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)!)
''')
            signed = json.loads(subprocess.check_output(["swift", str(signer), str(archive)]))
            verifier = pathlib.Path(__file__).parents[1] / "verify-signature.swift"
            executable = root / "verify-signature"
            subprocess.run(["swiftc", str(verifier), "-o", str(executable)], check=True, capture_output=True)
            command = [str(executable), str(archive), signed["publicKey"], signed["signature"]]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            archive.write_bytes(b"Synthetic update")
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
