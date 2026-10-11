import Foundation

// The few fields of the app's records the extracted declarations read.
struct ProfileRecord {
    var modelId: String
    var contextWindow: Int
    var maxOutputTokens: Int
    var modelOutputLimit: Int?
    var miniModelId: String?
    var advancedJSON: String = "{}"
    var configuration: [String: WireValue] {
        (try? JSONDecoder().decode(WireValue.self, from: Data(advancedJSON.utf8)))?.object ?? [:]
    }
}
struct ChatRecord {
    var model: String?
    var thinkingLevel: String?
    var contextWindow: Int?
    var maxOutputTokens: Int?
    var modelOutputLimit: Int?
}
struct TranscriptMessage {
    var role: String
    var text: String
    var endedUnfinished = false
    var truncated: Bool?
    var tools: [String]?
}
