import Foundation
import SQLite3

// Swift 0.1.122's MetadataStore writes a desktop.sqlite the way the app does,
// and lists it the way the sidebar does (`loadChats`): the oracle for the
// Rust importer's reading of a Swift chat list.
//   metadata-oracle generate OUTDIR

let out = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let databaseURL = out.appendingPathComponent("desktop.sqlite")
for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databaseURL.path + suffix) }
let store = MetadataStore(url: databaseURL)
let base = Date(timeIntervalSinceReferenceDate: 780_000_000)
let projectA = WorkspaceRecord(id: "W-A", path: "/Users/someone/project-a", trusted: true, paths: ["/Users/someone/shared"])
let projectB = WorkspaceRecord(id: "W-B", path: "/Users/someone/project-b", trusted: false)
let scratch = WorkspaceRecord(id: WorkspaceRecord.scratchID, path: "/Users/someone/Library/Scratch", trusted: true)
for workspace in [projectA, projectB, scratch] { try await store.put(workspace, kind: "workspace", id: workspace.id) }
let topic = TopicRecord(id: "T-1", workspaceID: "W-A", title: "Parser work", createdAt: base, expanded: false, revision: 3)
try await store.put(topic, kind: TopicRecord.recordKind, id: topic.id)

func chat(_ id: String, _ workspace: String, _ title: String, order: Int64?) -> ChatRecord {
    var record = ChatRecord(id: id, workspaceID: workspace, title: title, path: "/Users/someone/Library/Application Support/com.belloware.PiApp/sessions/\(id).jsonl", profileID: "P-1")
    record.sidebarOrder = order
    return record
}
var records: [ChatRecord] = []
var plain = chat("C-plain", "W-A", "Plain chat", order: 1_791_000_000_000_000); plain.lastActivityAt = 1_791_500_000_000_000; records.append(plain)
var pinned = chat("C-pinned", "W-A", "Pinned chat", order: 1_790_000_000_000_000); pinned.pinnedAt = base.addingTimeInterval(60); records.append(pinned)
var archived = chat("C-archived", "W-A", "Archived chat", order: 1_789_000_000_000_000); archived.archivedAt = base.addingTimeInterval(120); records.append(archived)
var topical = chat("C-topic", "W-A", "In a topic", order: 1_788_000_000_000_000); topical.topicID = "T-1"; topical.titleWasEdited = true; records.append(topical)
var side = chat("C-side", "W-A", "A kept side", order: 1_787_000_000_000_000); side.parentSessionID = "C-plain"; records.append(side)
var other = chat("C-other", "W-B", "Other project", order: 1_786_000_000_000_000); records.append(other)
var title = chat("C-title", WorkspaceRecord.scratchID, TitleGenerationPlan.fixedTitle, order: 1_785_000_000_000_000); title.backgroundTask = "title"; title.sourceSessionID = "C-plain"; title.toolMode = ChatRecord.readOnlyTools; records.append(title)
var test = chat("C-test", WorkspaceRecord.scratchID, "Connection test", order: 1_784_000_000_000_000); test.connectionTest = true; records.append(test)
var tuned = chat("C-tuned", "W-A", "With overrides", order: 1_783_000_000_000_000)
tuned.model = "gpt-6.1"; tuned.thinkingLevel = "high"; tuned.contextWindow = 400_000; tuned.maxOutputTokens = 32_000; tuned.modelOutputLimit = 128_000
tuned.costLimit = .usd(2.5); tuned.webhookOff = true; tuned.imported = true; records.append(tuned)
var unordered = chat("C-unordered", "W-A", "Before ordering", order: nil); records.append(unordered)
var pathless = chat("C-pathless", "W-A", "Never sent", order: 1_782_000_000_000_000); pathless.path = nil; records.append(pathless)
for record in records { try await store.put(record, kind: "chat", id: record.id) }
try await store.put(DraftRecord(id: "C-plain", text: "Unsent words", attachments: nil, skills: nil), kind: "draft", id: "C-plain")

// Rows another version wrote: one this build cannot decode, one too large.
var database: OpaquePointer?
guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { fatalError("open") }
// (An oversized row is left to the Rust test, which adds one: the rule is size alone.)
for (id, value) in [("C-foreign", #"{"id":"C-foreign","title":"No workspace"}"#), ("C-old", #"{"id":"C-old","workspaceID":"W-A","title":"Before tool modes","profileID":"P-1","imported":false}"#)] {
    let sql = "INSERT INTO records(kind,id,value,revision) VALUES('chat',?,?,1)"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { fatalError("prepare") }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, id, -1, transient)
    let bytes = Array(value.utf8)
    sqlite3_bind_blob(statement, 2, bytes, Int32(bytes.count), transient)
    guard sqlite3_step(statement) == SQLITE_DONE else { fatalError("insert") }
    sqlite3_finalize(statement)
}
// The store as the app leaves it, before a listing upgrades any row.
guard sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK else { fatalError("checkpoint") }
sqlite3_close(database)
let fixture = out.appendingPathComponent("swift-desktop.sqlite")
try? FileManager.default.removeItem(at: fixture)
try FileManager.default.copyItem(at: databaseURL, to: fixture)

// The sidebar's listing, in its order, each record as the app re-encodes it.
let listed = try await store.loadChats()
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
let chats = try listed.map { try JSONSerialization.jsonObject(with: encoder.encode($0)) }
let unlisted = await store.unlistedChats
let oracle: [String: Any] = ["chats": chats, "unlisted": unlisted]
try JSONSerialization.data(withJSONObject: oracle, options: [.sortedKeys]).write(to: out.appendingPathComponent("swift-listing.json"))
print("generated", listed.count, "listed,", unlisted, "unlisted")
