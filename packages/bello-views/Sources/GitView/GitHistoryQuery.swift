import Foundation

/// A value captured before any read starts. Hash navigation is deliberately
/// absent: opening a commit must never insert a row into filtered pagination.
public struct GitHistoryQuery: Equatable, Sendable {
    public enum Scope: Equatable, Sendable {
        case current, all, reference(String)
    }
    public let scope: Scope
    public let message: String
    public let author: String
    public let path: String?
    public let dates: GitHistoryDates

    public init(scope: Scope = .current, message: String = "", author: String = "", path: String? = nil,
                dates: GitHistoryDates = .init()) {
        self.scope = scope; self.message = message; self.author = author; self.path = path; self.dates = dates
    }
    public init(filter: GitLogFilter, options: GitHistoryOptions = .init()) {
        self.init(scope: options.reference.map(Scope.reference) ?? (filter.allBranches ? .all : .current),
                  message: filter.text, author: filter.author, path: filter.path, dates: options.dates)
    }
}

/// Additional controls live outside the legacy message/author/path API so
/// existing file-history and blame callers retain their contracts.
public struct GitHistoryOptions: Equatable, Sendable {
    public var reference: String?
    public var dates: GitHistoryDates
    public init(reference: String? = nil, dates: GitHistoryDates = .init()) { self.reference = reference; self.dates = dates }
}

/// Inclusive calendar days, always committed dates in UTC. Strict ISO input
/// avoids locale-dependent Git date parsing and DST/end-of-day ambiguity.
public struct GitHistoryDates: Equatable, Sendable {
    public let from: String
    public let through: String
    public init(from: String = "", through: String = "") { self.from = from; self.through = through }
    public var isEmpty: Bool { from.isEmpty && through.isEmpty }
    public func bounds() throws -> (from: Int?, through: Int?) {
        func day(_ value: String) throws -> Int? {
            if value.isEmpty { return nil }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = Calendar(identifier: .gregorian)
            format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
            guard value.utf8.count == 10, let date = format.date(from: value), format.string(from: date) == value else {
                throw GitFailure(message: "Enter a date as YYYY-MM-DD, for example 2026-10-14.")
            }
            return Int(date.timeIntervalSince1970)
        }
        let start = try day(from), end = try day(through)
        if let start, let end, start > end { throw GitFailure(message: "The start date must be on or before the end date.") }
        return (start, end.map { $0 + 86_399 })
    }
}

public struct GitHistoryRef: Equatable, Sendable, Identifiable {
    public let name: String
    public let object: String
    public var id: String { name }
    public var title: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
        return name
    }
    public var kind: String { name.hasPrefix("refs/tags/") ? "Tag" : name.hasPrefix("refs/remotes/") ? "Remote branch" : "Branch" }
}

/// Every page walks these immutable commit IDs, even if a branch moves while
/// the reader is paging. The identity also retires an earlier identical query.
public struct GitHistorySnapshot: Equatable, Sendable {
    public let id: UUID
    public let root: String
    public let query: GitHistoryQuery
    public let tips: [String]
    public init(root: String, query: GitHistoryQuery, tips: [String]) {
        id = UUID(); self.root = root; self.query = query; self.tips = tips
    }
}

public struct GitHistoryCursor: Equatable, Sendable {
    public let snapshot: UUID
    public let offset: Int
}
public struct GitHistoryPage: Equatable, Sendable {
    public let commits: [GitCommit]
    public let next: GitHistoryCursor?
}
