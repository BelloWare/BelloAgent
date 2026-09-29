/// The virtual key codes the app reads itself, by name. A code says where the
/// key is on the keyboard, whatever character it types (Carbon's `kVK_`
/// values).
enum KeyCode {
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    /// The key that deletes backward.
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let forwardDelete: UInt16 = 117
    /// Help on a Mac keyboard, Insert on a PC one.
    static let help: UInt16 = 114
    static let home: UInt16 = 115
    static let end: UInt16 = 119
    static let pageUp: UInt16 = 116
    static let pageDown: UInt16 = 121
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    /// F1 to F12, in order.
    static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    /// Return, or Enter on the keypad.
    static func isReturn(_ code: UInt16) -> Bool { code == returnKey || code == keypadEnter }
}
