import Foundation

/// A reference to the retained journal, not an export of the visible transcript.
/// Building it requires no file reads, history loading or helper startup.
struct SessionReference {
    let chat: ChatRecord

    var text: String {
        var lines = [
            "Bello Agent session",
            "App session ID: \(chat.id)",
            "Title: \(chat.title)",
            "Project ID: \(chat.workspaceID)"
        ]
        if let parent = chat.parentSessionID { lines.append("Parent session ID: \(parent)") }
        if let path = chat.path, !path.isEmpty {
            lines += [
                "Conversation file (JSONL): \(path)",
                "",
                "Read with Bash:",
                "cat -- \(Self.shellQuote(path))",
                "",
                "Retained JSONL history includes messages, tool results, prior branches and compaction metadata, not just the current model context. Live streaming output appears after it is saved; unsaved drafts are not included. Read the file without modifying it."
            ]
            if chat.imported {
                lines.append("Imported original: the app session ID above may differ from the session ID in the file header.")
            }
        } else {
            lines.append("Conversation file: not created yet. This session has no saved journal to inspect.")
        }
        return lines.joined(separator: "\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
