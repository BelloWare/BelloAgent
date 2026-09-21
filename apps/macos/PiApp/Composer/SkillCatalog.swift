import Foundation

struct SkillCatalog: Sendable {
    enum State: String, Sendable { case loading, ready, failed, partial }
    var state: State = .loading
    var scope = ""
    var revision = ""
    var entries: [SkillSearch.Entry] = []
    var notice = ""
    var authorizes: Bool { state == .ready || state == .partial }
}
