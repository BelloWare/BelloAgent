import XCTest
@testable import PiAgentCore

final class JournalPromotionPerformanceTests: HelperTestCase {
    func testGenerated200MBPromotionUnderFamilyGate() async throws {
        guard ProcessInfo.processInfo.environment["PI_PROMOTION_PERF"] == "1" else { throw XCTSkip("Opt-in Release promotion measurement") }
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at:root) }
        let journal = try SessionJournal(url:root.appendingPathComponent("large.jsonl"),id:"large",cwd:root,binding:fixtureProfile().binding,create:true)
        let payload = String(repeating:"x",count:3960)
        for i in 0..<50000 {
            try journal.append(["type":"message","message":ChatMessage(role:i % 2 == 0 ? "user" : "assistant",content:[textBlock(payload)]).pi],id:"row-\(i)",flush:false)
        }
        try journal.synchronize()
        let size = try FileManager.default.attributesOfItem(atPath:journal.url.path)[.size] as! NSNumber
        let gate = AsyncGate()
        for (version, promote) in [("v3", { try journal.promoteToSteering(managedChild:false) }), ("v4", { try journal.promoteToCodex(managedChild:false) }), ("v5", { try journal.promoteToMailboxCut(managedChild:false) })] {
            let wall = ContinuousClock.now
            try await gate.acquire(); let held = ContinuousClock.now
            try promote()
            let holdTime = held.duration(to:.now)
            await gate.release()
            print("PROMOTION \(version) bytes=\(size) wall=\(wall.duration(to:.now)) family_gate=\(holdTime)")
        }
    }
}
