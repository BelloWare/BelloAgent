import Foundation

// Every key the Swift 0.1.122 TerminalKeyEncoder knows, under every modifier
// mix and both cursor modes, as the bytes it sends (hex), one line each.
let keys: [(String, TerminalKeyEncoder.Key)] = [
    ("up", .up), ("down", .down), ("left", .left), ("right", .right), ("home", .home), ("end", .end),
    ("pageUp", .pageUp), ("pageDown", .pageDown), ("insert", .insert), ("delete", .delete), ("tab", .tab),
    ("backTab", .backTab), ("enter", .enter), ("escape", .escape), ("backspace", .backspace),
] + (1...12).map { ("f\($0)", TerminalKeyEncoder.Key.function($0)) }
for (name, key) in keys {
    for application in [false, true] {
        for bits in 0..<8 {
            let shift = bits & 1 != 0, control = bits & 2 != 0, option = bits & 4 != 0
            let data = TerminalKeyEncoder.encode(key, applicationCursor: application, shift: shift, control: control, option: option)
            print("\(name) \(application ? 1 : 0) \(shift ? 1 : 0) \(control ? 1 : 0) \(option ? 1 : 0) \(data.map { String(format: "%02x", $0) }.joined())")
        }
    }
}
// Key codes to keys.
for code in UInt16(0)...UInt16(130) {
    for shift in [false, true] {
        if let key = TerminalKeyEncoder.key(forKeyCode: code, shift: shift) { print("code \(code) \(shift ? 1 : 0) \(key)") }
    }
}
