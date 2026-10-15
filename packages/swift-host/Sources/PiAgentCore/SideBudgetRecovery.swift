import Foundation

/// Cold-open migration/repair reads only origin and accounting records. The
/// owner's journal receives numeric usage, never side conversation content.
enum SideBudgetRecovery {
    struct Origin {
        var id: String
        var parent: String
        var file: URL
    }
    static func parentExists(_ id: String, directory: URL) throws -> Bool {
        try journalURL(id,directory:directory) != nil
    }
    static func journalURL(_ id: String, directory: URL) throws -> URL? {
        let id = try identity(JSON(id))
        for name in [id, "side_" + id, "fork_" + id] {
            let file = canonical(directory.appendingPathComponent(name + ".jsonl").path)
            guard within(file,canonical(directory.path)) else { throw AttemptAccounting.damaged() }
            do {
                _ = try FileManager.default.attributesOfItem(atPath:file.path)
                return file
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { }
        }
        return nil
    }

    static func unkeyedCharge(spend: SessionSpend, accounting: AttemptAccounting, side: String, parents: [String]) -> JSON? {
        var remainder = spend
        for entry in accounting.attempts.values {
            var counted = SessionSpend(); counted.add(record: entry.effective)
            remainder.usd -= counted.usd; remainder.reported -= counted.reported; remainder.unreported -= counted.unreported
        }
        guard remainder.reported > 0 || remainder.unreported > 0 || remainder.usd > 0.000000000001 else { return nil }
        var seed = remainder.record
        seed["usd"] = JSON(max(0,remainder.usd)); seed["attemptId"] = JSON("side-history:" + side)
        seed["source"] = "side-history"; seed["outcome"] = "completed"; seed["purpose"] = "legacy"
        return charge(seed,side:side,parents:parents)
    }
    static func charges(owner: String, directory: URL) throws -> [AccountingRecord] {
        var result: [AccountingRecord] = []
        for (origin, parents) in try savedFamily(owner:owner,directory:directory) {
            // Only this family's ledger can affect opening its owner. An
            // unrelated side's damaged tail must not prevent other chats
            // opening; damage in a related ledger must still fail closed.
            let reader = try JournalRecordReader(origin.file)
            var accounting = AttemptAccounting(), remainder = SessionSpend()
            while let line = try reader.nextLine() {
                if line.isEmpty { continue }
                let record = try JSON.parse(line)
                try accounting.consumeRecord(record,sessionID:origin.id,spend:&remainder)
            }
            for key in accounting.attempts.keys.sorted() {
                let entry = accounting.attempts[key]!
                if let record = record(entry,side:origin.id,parents:parents) { result.append(record) }
            }
            if let seed = unkeyedCharge(spend:remainder,accounting:accounting,side:origin.id,parents:parents) {
                result.append(AccountingRecord(kind:JournalRecordKind.cost,data:seed))
            }
        }
        return result
    }
    static func savedFamily(owner: String, directory: URL) throws -> [(origin: Origin, parents: [String])] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var origins: [String: Origin] = [:]
        for file in files where file.lastPathComponent.hasPrefix("side_") && file.pathExtension == "jsonl" {
            guard within(canonical(file.path), canonical(directory.path)) else { continue }
            // Membership is not established yet. An unreadable/incomplete
            // unrelated file must not block the workspace; opening that file
            // still reports its ordinary damaged-history/recovery error.
            // Once an origin links it to this owner, charges reads strictly.
            if let origin = try? readOrigin(file) { origins[origin.id] = origin }
        }
        var result: [(origin: Origin, parents: [String])] = []
        for origin in origins.values.sorted(by: { $0.id < $1.id }) {
            var parents: [String] = [], next = origin.parent, seen: Set<String> = [origin.id]
            while seen.insert(next).inserted, parents.count < 128 {
                parents.append(next)
                if next == owner { break }
                guard let parent = origins[next]?.parent else { break }
                next = parent
            }
            guard parents.last == owner else { continue }
            result.append((origin, parents))
        }
        return result
    }
    private static func readOrigin(_ file: URL) throws -> Origin? {
        let reader = try JournalRecordReader(file)
        var id: String?
        while let line = try reader.nextLine() {
            guard !line.isEmpty, let record = try? JSON.parse(line) else { continue }
            if record["type"].text == "session" { id = record["id"].text }
            guard record["customType"].text == JournalRecordKind.sideOrigin else { continue }
            guard let id, let parent = record["data"]["parentSessionId"].text,
                  record["data"]["relationship"].text != "fork", file.lastPathComponent == "side_" + id + ".jsonl" else { return nil }
            return Origin(id:id,parent:parent,file:file)
        }
        return nil
    }
    static func charge(_ original: JSON, side: String, parents: [String]) -> JSON {
        // An allowlist is deliberate: even a malformed side cost record can
        // never copy arbitrary side content into the parent journal.
        var data = original.map.filter { ["attemptId","sourceSessionId","budgetOwnerSessionId","delegationId","purpose","outcome","usd","reported","unreported","usage","usageStatus","status","source","scope","sideParents","wallTimestamp"].contains($0.key) }
        if data["sourceSessionId"] == nil { data["sourceSessionId"] = JSON(side) }
        if data["budgetOwnerSessionId"] == nil { data["budgetOwnerSessionId"] = JSON(side) }
        if data["sideParents"] == nil { data["sideParents"] = .array(parents.map { JSON($0) }) }
        return .object(data)
    }
}
