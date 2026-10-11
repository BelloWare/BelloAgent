import Foundation
var out = ""
var start: UInt32 = 0, current = -1
func flush(_ end: UInt32) { if current != 1 && current != -1 { out += "\(String(start, radix: 16)) \(String(end, radix: 16)) \(current)\n" } }
var v: UInt32 = 0
while v <= 0x10ffff {
    let w: Int
    if let s = Unicode.Scalar(v) { w = TerminalEmulator.width(of: s) } else { w = 1 }
    if w != current { if v > 0 { flush(v - 1) }; start = v; current = w }
    v += 1
}
flush(0x10ffff)
print(out, terminator: "")
