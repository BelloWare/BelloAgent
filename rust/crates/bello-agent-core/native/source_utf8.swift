import Foundation

// A public Objective-C ABI; no Swift values or ownership cross the boundary.
// Only generated or already-admitted, bounded bytes reach this synchronous API.
@objc(BelloAgentRustSourceUTF8Decoder)
public final class SourceUTF8Decoder: NSObject {
    // 0: success, 1: source returned nil, 2: capacity query, 3: invalid contract.
    // On every non-success return the output buffer remains untouched.
    @objc(decodeInput:length:output:capacity:written:)
    public static func decode(_ input: UnsafePointer<UInt8>?, length: UInt,
                              output: UnsafeMutablePointer<UInt8>?, capacity: UInt,
                              written: UnsafeMutablePointer<UInt>?) -> Int32 {
        guard let written else { return 3 }
        written.pointee = 0
        guard length <= 16 * 1024 * 1024,
              length == 0 || input != nil else { return 3 }
        let data = length == 0 ? Data() : Data(bytes: input!, count: Int(length))
        // Tools.swift's actual decoder. Do not substitute NSString, a BOM
        // heuristic, String(decoding:as:), or a compiler/OS version condition.
        guard let text = String(data: data, encoding: .utf8) else { return 1 }
        let needed = text.utf8.count
        written.pointee = UInt(needed)
        guard UInt(needed) <= capacity else { return 2 }
        guard needed == 0 || output != nil else { return 3 }
        for (index, byte) in text.utf8.enumerated() {
            output![index] = byte
        }
        return 0
    }
}
