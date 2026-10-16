import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Native cold-reader metadata. The runtime gate protects writer ownership;
/// this separate actor keeps file checks and replay off the host command actor.
/// File identity/size/nanosecond stamps invalidate every append or replacement.
actor ChildBudgetReadings {
    private struct Entry { var stamp: SideOriginIndex.Stamp; var origin: SubagentOrigin; var cost: JSON }
    private var cache: [String:Entry] = [:]
    func read(plan: SubagentPlan, directory: URL, allowMissing: Bool = false) throws -> JSON {
        let id = try identity(JSON(plan.origin.link.childSessionID))
        let file = directory.appendingPathComponent(id + ".jsonl")
        func stamp() throws -> SideOriginIndex.Stamp? {
            var info = stat()
            let result = lstat(file.path,&info)
            // Older accepted-but-unstarted delegations have no child journal.
            // Only that absent-file case is optional; damaged or unreadable
            // existing ledgers must retain the normal recovery error.
            if result != 0, errno == ENOENT, allowMissing { return nil }
            guard result == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw AgentError("file_unavailable","Cannot read managed child accounting")
            }
            return SideOriginIndex.Stamp(info)
        }
        guard let before = try stamp() else { return .null }
        if let entry = cache[file.path], entry.stamp == before, entry.origin == plan.origin { return entry.cost }
        let cost = try SubagentRecovery.mirrorCapturedCosts([],plan:plan,directory:directory)
        guard try stamp() == before else { throw AgentError("session_damaged","Managed child accounting changed during its read") }
        if cache.count >= 512 { cache.removeAll(keepingCapacity:true) }
        cache[file.path] = Entry(stamp:before,origin:plan.origin,cost:cost)
        return cost
    }
}
