import Foundation

/// Opt-in local metadata only. The bounded file is replaced, never uploaded.
/// No prompt, header, credential, model configuration or skill content is read.
@MainActor final class ContextDiagnostics {
    static let shared=ContextDiagnostics(output:ProcessInfo.processInfo.environment["BELLO_CONTEXT_DIAGNOSTICS"].flatMap {
        $0.hasPrefix("/") ? URL(fileURLWithPath:$0) : nil
    })
    let output: URL?
    private(set) var events: [[String: WireValue]]=[]
    private var selected: [String: [String: WireValue]]=[:]
    private var writing=false, pending=false
    init(output: URL?) { self.output=output }
    func record(sessionID: String, state: [String: WireValue], presentation: ContextPresentation) {
        guard output != nil else { return }
        var value: [String: WireValue]=["sessionID":.string(String(sessionID.prefix(128))),"scope":.string(presentation.scope),"reason":.string(presentation.reason)]
        for key in ["runtimeEpoch","replayRevision","generation"] { value[key]=state[key] }
        let request=state[presentation.scope == "last-request" ? "lastRequest":"currentRequest"]?.object
        value["attemptID"]=request?["attemptID"]
        if let generation=request?["generation"] { value["generation"]=generation }
        for key in ["tokens","method","estimated"] { value[key]=presentation.context[key] }
        guard selected[sessionID] != value else { return }
        if selected.count >= 256, selected[sessionID] == nil { selected.removeAll(keepingCapacity:true) }
        selected[sessionID]=value
        value["at"] = .number(Date().timeIntervalSince1970)
        events.append(value); if events.count > 256 { events.removeFirst(events.count-256) }
        pending=true; flush()
    }
    private func flush() {
        guard !writing, pending, let output else { return }
        writing=true; pending=false
        Task { [self] in
            try? await Task.sleep(for:.milliseconds(250))
            let retained=events
            await Task.detached(priority:.utility) {
                guard let data=try? JSONEncoder().encode(retained) else { return }
                try? data.write(to:output,options:[.atomic,.completeFileProtectionUnlessOpen])
                try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:output.path)
            }.value
            writing=false
            if pending { flush() }
        }
    }
}
