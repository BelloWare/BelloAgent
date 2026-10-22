import Foundation
import GitProcessSafety

/// A lexical path: building header buttons never stats a slow volume.
public struct FileBreadcrumb: Equatable, Sendable {
    public let title: String
    public let url: URL
    public let isDirectory: Bool
    public var ancestors: [FileBreadcrumb] = []

    public static func normalized(_ url: URL) -> URL { URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false) }

    public static func contains(_ file: URL, in root: URL) -> Bool {
        let path = file.standardizedFileURL.path, base = root.standardizedFileURL.path
        return path == base || path.gitHasPrefix(base == "/" ? "/" : base + "/")
    }

    public static func path(to file: URL, project: (String, URL)? = nil,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [FileBreadcrumb] {
        let file = normalized(file), home = normalized(home)
        let base: URL, title: String
        if let project, contains(file, in: project.1) { base = normalized(project.1); title = project.0 }
        else if contains(file, in: home) { base = home; title = "~" }
        else { base = URL(fileURLWithPath: "/"); title = "/" }
        var result = [FileBreadcrumb(title: title, url: base, isDirectory: true)]
        var cursor = base
        for component in file.pathComponents.dropFirst(base.pathComponents.count) {
            cursor = normalized(cursor.appendingPathComponent(component, isDirectory: false))
            result.append(FileBreadcrumb(title: component, url: cursor, isDirectory: cursor != file))
        }
        return result
    }

    /// Keep the root and as much of the end as fits. The ellipsis retains
    /// every hidden ancestor, including at widths smaller than three buttons.
    public static func collapsed(_ crumbs: [FileBreadcrumb], width: Double, measure: (String) -> Double) -> [FileBreadcrumb] {
        func size(_ values: [FileBreadcrumb]) -> Double { values.reduce(0) { $0 + measure($1.title) } + Double(max(0, values.count - 1)) * 12 }
        guard crumbs.count > 2, size(crumbs) > width else { return crumbs }
        var hidden = 1
        while hidden < crumbs.count - 2 {
            let count = hidden + 1
            let candidate = [crumbs[0], FileBreadcrumb(title: "…", url: crumbs[1].url, isDirectory: true)] + crumbs.dropFirst(count)
            if size(candidate) <= width { break }
            hidden += 1
        }
        var ellipsis = FileBreadcrumb(title: "…", url: crumbs[1].url, isDirectory: true)
        ellipsis.ancestors = Array(crumbs[1...hidden])
        return [crumbs[0], ellipsis] + crumbs.dropFirst(hidden + 1)
    }
}
