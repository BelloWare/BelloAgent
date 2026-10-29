import Foundation

/// A size/work preflight for optional checkpoints, before Codable allocates
/// their JSON trees. It counts a conservative JSON byte bound and stops at
/// the budget. Nothing is truncated: an oversized cache is simply skipped.
final class CheckpointEncodingBudget {
    struct Exceeded: Error {}
    private var remaining: Int
    init(bytes: Int) { remaining = bytes }
    func check<T: Encodable>(_ value: T) throws {
        try value.encode(to: Counter(budget: self))
        try charge(0)
    }
    fileprivate func charge(_ bytes: Int) throws {
        guard bytes <= remaining else { throw Exceeded() }
        remaining -= bytes
    }
    fileprivate func container() { remaining -= 2 }
    fileprivate func element() { remaining -= 1 }
    fileprivate func nestedKey(_ key: String) {
        do { try string(key); try charge(2) } catch { remaining = -1 }
    }
    fileprivate func string(_ text: String) throws {
        try charge(2)
        for byte in text.utf8 {
            // Controls may use six bytes. Non-ASCII bytes leave room for
            // either literal UTF-8 or escaped UTF-16 in Foundation's encoder.
            remaining -= byte < 0x20 ? 6 : byte == 0x22 || byte == 0x5c ? 2 : byte >= 0x80 ? 3 : 1
            if remaining < 0 { throw Exceeded() }
        }
    }
    fileprivate func value<T: Encodable>(_ value: T) throws {
        if let text = value as? String { try string(text) }
        else if value is Bool { try charge(5) }
        else if value is any FixedWidthInteger || value is Double || value is Float { try charge(32) }
        else { try check(value) }
    }
}

private struct Counter: Encoder {
    let budget: CheckpointEncodingBudget
    var codingPath: [any CodingKey] { [] }
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func container<Key: CodingKey>(keyedBy: Key.Type) -> KeyedEncodingContainer<Key> {
        budget.container(); return KeyedEncodingContainer(Keyed<Key>(encoder: self))
    }
    func unkeyedContainer() -> any UnkeyedEncodingContainer { budget.container(); return Values(encoder: self) }
    func singleValueContainer() -> any SingleValueEncodingContainer { Values(encoder: self) }

    struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let encoder: Counter
        var codingPath: [any CodingKey] { [] }
        private func key(_ key: Key) throws { try encoder.budget.string(key.stringValue); try encoder.budget.charge(2) }
        mutating func encodeNil(forKey key: Key) throws { try self.key(key); try encoder.budget.charge(4) }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try self.key(key); try encoder.budget.value(value) }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
            encoder.budget.nestedKey(key.stringValue); return encoder.container(keyedBy: keyedBy)
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer { encoder.budget.nestedKey(key.stringValue); return encoder.unkeyedContainer() }
        mutating func superEncoder() -> any Encoder { encoder.budget.nestedKey("super"); return encoder }
        mutating func superEncoder(forKey key: Key) -> any Encoder { encoder.budget.nestedKey(key.stringValue); return encoder }
    }
    struct Values: UnkeyedEncodingContainer, SingleValueEncodingContainer {
        let encoder: Counter
        var codingPath: [any CodingKey] { [] }
        var count = 0
        mutating func encodeNil() throws { count += 1; try encoder.budget.charge(5) }
        mutating func encode<T: Encodable>(_ value: T) throws { count += 1; try encoder.budget.charge(1); try encoder.budget.value(value) }
        mutating func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
            count += 1; encoder.budget.element(); return encoder.container(keyedBy: keyedBy)
        }
        mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { count += 1; encoder.budget.element(); return encoder.unkeyedContainer() }
        mutating func superEncoder() -> any Encoder { count += 1; encoder.budget.element(); return encoder }
    }
}
