import Foundation

struct ReplyFileLocation: Hashable, Sendable {
    let path: String
    let line: Int?
}

/// Filesystem work and its bounded cache live on this actor, away from UI
/// drawing. The complete trust configuration participates in each key.
actor ReplyFileResolver {
    struct Root: Hashable, Sendable { let path: String; let trusted: Bool }
    struct Context: Hashable, Sendable { let roots: [String]; let projects: [Root] }
    private struct Key: Hashable { let text: String; let context: Context }
    private struct Entry { let location: ReplyFileLocation?; let madeAt: Date }
    private var cache: [Key: Entry] = [:]
    private(set) var fileChecks = 0

    func resolve(_ text: String, in context: Context) -> ReplyFileLocation? {
        guard !context.roots.isEmpty, !text.isEmpty, text.utf8.count <= 4_096,
              !text.contains("\n"), !text.contains("\r"), !text.contains("://") else { return nil }
        let key = Key(text: text, context: context)
        if let entry = cache[key], Date().timeIntervalSince(entry.madeAt) < 2 { return entry.location }
        var path = text, line: Int?
        if let colon = path.lastIndex(of: ":"), let number = Int(path[path.index(after: colon)...]), number > 0 {
            line = number; path = String(path[..<colon])
        }
        path = (path as NSString).expandingTildeInPath
        let candidates = path.hasPrefix("/") ? [path] : context.roots.map { ($0 as NSString).appendingPathComponent(path) }
        let projects = context.projects.map { (path: URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path, trusted: $0.trusted) }
        var location: ReplyFileLocation?
        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath()
            let owner = projects.filter { url.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
                .max { $0.path.count < $1.path.count }
            guard owner?.trusted == true else { continue }
            fileChecks += 1
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            location = ReplyFileLocation(path: url.path, line: line)
            break
        }
        if cache.count >= 256, let oldest = cache.min(by: { $0.value.madeAt < $1.value.madeAt })?.key { cache[oldest] = nil }
        cache[key] = Entry(location: location, madeAt: Date())
        return location
    }
}

extension WorkspaceModel {
    func resolveReplyFile(_ text: String, fromChat sessionID: String) async -> ReplyFileLocation? {
        guard let id = record(sessionID)?.workspaceID, let project = workspace(for: id), project.trusted, !project.isScratch else { return nil }
        let context = ReplyFileResolver.Context(roots: project.roots,
            projects: workspaces.filter { !$0.isScratch }.flatMap { project in project.roots.map { ReplyFileResolver.Root(path: $0, trusted: project.trusted) } })
        return await replyFileResolver.resolve(text, in: context)
    }
}
