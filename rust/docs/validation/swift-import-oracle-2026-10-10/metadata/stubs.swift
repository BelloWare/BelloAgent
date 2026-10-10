import Foundation
// Stand-ins for app types MetadataStore names in code paths the oracle never
// runs (title claims, portable handoff, errors). None is encoded into a chat,
// workspace, topic or draft record.
enum HostError: Error { case failure(String) }
struct ChatModelDefaults: Codable { static let recordKind = "chat-model-defaults"; init(chat: ChatRecord) {} }
enum BackgroundRequestKind: String { case title; var raw: String { rawValue } }
enum TitleGenerationPlan { static let fixedTitle = "Title" }
struct TranscriptAnchor: Codable, Sendable {}
// Display formatting only (CostLimit labels); nothing encoded uses them.
enum MetricFormat { static func centsUSD(_ value: Double, places: Int, padded: Bool) -> String { "" } }
func compactGatewayUSD(_ value: Double?) -> String { "" }
