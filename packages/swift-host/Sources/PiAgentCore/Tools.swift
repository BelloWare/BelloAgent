import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func resultText(_ text: String, error: Bool = false) -> JSON { ["content": .array([textBlock(text)]), "isError": JSON(error)] }
/// Approximate +added/-removed line counts: lines shared as a common prefix and
/// suffix are unchanged, everything between counts once on each side.
func lineDiffStats(_ old: String, _ new: String) -> (added: Int, removed: Int) {
    let a = old.isEmpty ? [] : old.components(separatedBy: "\n"), b = new.isEmpty ? [] : new.components(separatedBy: "\n")
    var prefix = 0; while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0; while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
    return (b.count - prefix - suffix, a.count - prefix - suffix)
}
func objectSchema(_ properties: JSON, required: [String]) -> JSON { ["type":"object", "properties": properties, "required": .array(required.map { JSON($0) }), "additionalProperties":false] }

/// Output is drained on both pipes even after its retention cap is reached.
/// The output file is private; only a bounded preview enters model context.
///
/// A command is complete when bash has exited and its output has reached end
/// of file. A process bash started can keep that output open for as long as
/// it lives (`server &`, or a daemon that left the group with setsid), so the
/// output is never waited on without bound: the result is returned a short
/// grace after bash exits, saying that a background process still held the
/// output, and the pipes are then closed. Stop and the deadline signal the
/// process group and wait for bash the same way, never for what escaped it.
///
/// Concurrency: `@unchecked` because the two pipe readers run on a serial
/// Dispatch queue, the termination handler and the grace timers on others.
/// The invariant is that every mutable property is read and written only
/// while `lock` is held, and that `continuation` is resumed exactly once:
/// `completeIfReady` clears it under the same lock that sets `finished`.
/// `child`, `file` and `url` are immutable; `file` is written only from
/// `consume`, under `lock` and before `finished`, and closed only after it.
final class ShellRun: @unchecked Sendable {
    /// How long output may stay open after bash exits by itself, and after
    /// it exits because Stop or the deadline signalled its group.
    static let exitGrace = 1.5, stopGrace = 0.5
    /// The longest Stop or the deadline waits for bash itself to be reaped.
    static let stopLimit = 3.0
    static let backgroundNote = "Note: a background process still held this command's output when bash exited, so output after that point was not read and the process may be stopped by SIGPIPE if it writes again. Redirect a background job's output to keep it running, for example: cmd > cmd.log 2>&1 &"
    let child: ManagedChild
    private let lock = NSLock(), file: FileHandle, url: URL
    private let readQueue = DispatchQueue(label: "pi.shell.output")
    private var sources: [DispatchSourceRead] = []
    private var previewBytes = Data(), observed = 0, retained = 0, openStreams = 2
    private var latestUpdate=0.0, publishedPreview = 0
    private let onUpdate: @Sendable (JSON) async -> Void
    private var exitCode: Int32?, continuation: CheckedContinuation<JSON, Error>?, cancellation = false, timedOut = false, finished = false, ioError = false
    /// Set by the grace timers: the output no longer has to reach end of file
    /// (`graceElapsed`, once bash has exited), and bash no longer has to be
    /// reaped (`stopElapsed`, the last resort after Stop or the deadline).
    private var graceElapsed = false, stopElapsed = false
    private var limitSeconds = 0
    init(command: String, cwd: URL, outputDirectory: URL, onUpdate: @escaping @Sendable (JSON) async -> Void) throws {
        self.onUpdate=onUpdate
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true, attributes:[.posixPermissions:0o700])
        url = outputDirectory.appendingPathComponent(UUID().uuidString + ".log")
        guard FileManager.default.createFile(atPath:url.path, contents:nil, attributes:[.posixPermissions:0o600]) else { throw AgentError("tool_output", "Cannot create retained tool output") }
        file = try FileHandle(forWritingTo:url)
        child = try ManagedChild(command:"/bin/bash", arguments:["--noprofile","--norc","-c",command], cwd:cwd, environment:toolEnvironment())
        try? child.input.fileHandleForWriting.close()
    }
    func run(timeoutSeconds: Int) async throws -> JSON {
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { c in
                lock.lock(); continuation = c; limitSeconds = timeoutSeconds; lock.unlock()
                child.process.terminationHandler = { [weak self] process in self?.exited(process.terminationStatus) }
                // A very short-lived process can exit before the handler is set.
                if !child.process.isRunning { exited(child.process.terminationStatus) }
                for handle in [child.output.fileHandleForReading, child.errors.fileHandleForReading] { startReading(handle) }
                // The command deadline. Bounded rather than owned: it sleeps
                // once, holds only a weak reference, and `expire` is a no-op
                // once the run has finished or been cancelled.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                    self?.expire()
                }
                if Task.isCancelled { cancel() }
            }
        }, onCancel: { [weak self] in self?.cancel() })
    }
    /// Reads one pipe without ever blocking a thread on it: a descriptor that
    /// a background process keeps open must not strand a worker for as long
    /// as that process lives. Closing is the cancel handler's job, after the
    /// source can no longer read the descriptor.
    private func startReading(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [self, unowned source] in
            var bytes = [UInt8](repeating: 0, count: 65_536)
            for _ in 0..<16 {
                let count = read(fd, &bytes, bytes.count)
                if count > 0 { consume(Data(bytes.prefix(count))); continue }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                if count < 0 { lock.lock(); ioError = true; lock.unlock(); child.stop() }
                source.cancel(); return
            }
        }
        source.setCancelHandler { [self] in try? handle.close(); streamClosed() }
        lock.lock(); sources.append(source); lock.unlock()
        source.resume()
    }
    private func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        observed += data.count
        if previewBytes.count < 32768 { previewBytes.append(data.prefix(32768 - previewBytes.count)) }
        let keep = data.prefix(max(0, 64 * 1024 * 1024 - retained))
        do { try file.write(contentsOf:keep); retained += keep.count } catch { ioError=true }
        // At most one live-output notice every 66 ms, and only when the
        // preview grew: once it holds its 32 KiB, more output changes nothing
        // the card shows. Handed to the session actor from the reader queue.
        // Unowned because it carries the preview by value and holds nothing:
        // a dropped notice would only leave the card showing the previous
        // preview until the next one.
        if previewBytes.count > publishedPreview, nowMS()-latestUpdate >= 66 {
            latestUpdate=nowMS(); publishedPreview=previewBytes.count
            let update=resultText(String(decoding:previewBytes,as:UTF8.self));let callback=onUpdate;Task { await callback(update) }
        }
    }
    private func exited(_ code: Int32) {
        lock.lock(); guard exitCode == nil else { lock.unlock(); return }
        exitCode=code; let grace = cancellation || timedOut ? Self.stopGrace : Self.exitGrace; lock.unlock()
        after(grace) { $0.graceElapsed = true }
        completeIfReady()
    }
    private func streamClosed() { lock.lock(); openStreams -= 1; lock.unlock(); completeIfReady() }
    private func cancel() {
        lock.lock(); if finished || cancellation { lock.unlock(); return }; cancellation=true; lock.unlock()
        stopGroup()
    }
    /// The deadline kills the process like a cancellation, but the outcome is
    /// reported to the model as a failed result so the turn can continue.
    private func expire() {
        lock.lock(); if finished || cancellation || timedOut { lock.unlock(); return }; timedOut=true; lock.unlock()
        stopGroup()
    }
    private func stopGroup() {
        child.stop()
        lock.lock(); let exited = exitCode != nil; lock.unlock()
        if exited { after(Self.stopGrace) { $0.graceElapsed = true } }
        after(Self.stopLimit) { $0.stopElapsed = true }
        completeIfReady()
    }
    /// Marks a grace as elapsed and completes if that was all it waited for.
    /// The timer holds the run weakly: a finished run has nothing to mark.
    private func after(_ seconds: Double, _ mark: @escaping @Sendable (ShellRun) -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            lock.lock(); mark(self); lock.unlock()
            completeIfReady()
        }
    }
    private func completeIfReady() {
        lock.lock()
        guard !finished, let c=continuation, (exitCode != nil && (openStreams == 0 || graceElapsed)) || stopElapsed else { lock.unlock(); return }
        finished=true; continuation=nil
        let code=exitCode, held=openStreams > 0, open=sources
        let cancelled=cancellation, expired=timedOut, limit=limitSeconds, failedIO=ioError, seen=observed, kept=retained, bytes=previewBytes; lock.unlock()
        // Whatever still holds the output is no longer read: closing the
        // pipes releases the readers, and the process is not waited for.
        for source in open { source.cancel() }
        child.finishedNormally();try? file.synchronize(); try? file.close()
        if cancelled { c.resume(throwing: CancellationError()); return }
        var text = String(decoding:bytes,as:UTF8.self) + "\nExit code: \(code.map(String.init) ?? "unknown")"
        if expired { text = "Command timed out after \(limit) seconds and was terminated. Re-run with a larger timeout (up to 600 seconds) or split the work.\n" + text }
        if seen > bytes.count { text += "\nOutput preview truncated. Retained \(kept) of \(seen) bytes at \(url.path). Use read with offset/limit to inspect." }
        if failedIO { text += "\nWarning: output could not be fully retained." }
        if held { text += "\n" + Self.backgroundNote }
        c.resume(returning:resultText(text,error:code != 0 || failedIO || expired))
    }
}

public actor NativeTools: ToolExecuting {
    public let cwd: URL, mcp: MCPManager
    /// Workspace roots, primary first. Relative paths resolve against the
    /// primary root; a relative path that is absent there but present under
    /// exactly one other root resolves to that root for existing files.
    public let roots: [URL]
    private let outputs: URL, files: FileToolContext, workers: BlockingWorkExecutor
    public init(cwd: URL, roots: [URL] = [], outputs: URL, mcp: MCPManager) {
        self.cwd=cwd; self.roots=workspaceRoots(primary:cwd,additional:roots); self.outputs=outputs; self.mcp=mcp
        self.files=FileToolContext(cwd:cwd,roots:self.roots); self.workers = .shared
    }
    init(cwd: URL, roots: [URL] = [], outputs: URL, mcp: MCPManager, workers: BlockingWorkExecutor) {
        self.cwd=cwd; self.roots=workspaceRoots(primary:cwd,additional:roots); self.outputs=outputs; self.mcp=mcp
        self.files=FileToolContext(cwd:cwd,roots:self.roots); self.workers=workers
    }
    public func definitions(readOnly: Bool) -> [ToolDefinition] {
        let s: JSON = ["type":"string"], n: JSON = ["type":"integer","minimum":1]
        var result = [
            ToolDefinition("read", "Read UTF-8 text. Offset is a 1-based line number; use limit for paging. Large output is truncated explicitly.", objectSchema(["path":s,"offset":n,"limit":n],required:["path"])),
            ToolDefinition("ls", "List a directory, including hidden entries. Results are sorted and bounded.", objectSchema(["path":s,"limit":n],required:[])),
            ToolDefinition("find", "Find paths matching a shell-style glob, relative to path (default workspace). No shell execution.", objectSchema(["pattern":s,"path":s,"limit":n],required:["pattern"])),
            ToolDefinition("grep", "Search UTF-8 files for a literal string or regular expression. Results include path and line number.", objectSchema(["pattern":s,"path":s,"literal":["type":"boolean"],"ignoreCase":["type":"boolean"],"limit":n],required:["pattern"]))
        ]
        if !readOnly {
            result += [
                ToolDefinition("write", "Write UTF-8 content to a file, creating parent directories. This replaces existing content.", objectSchema(["path":s,"content":s],required:["path","content"])),
                ToolDefinition("edit", "Replace exactly one occurrence of oldText with newText. Fails if text is missing or ambiguous; no fuzzy edit.", objectSchema(["path":s,"oldText":s,"newText":s],required:["path","oldText","newText"])),
                ToolDefinition("bash", "Run a non-interactive bash command in the workspace. Output is bounded and retained in a file when large. timeout is seconds (1–600).", objectSchema(["command":s,"timeout":n],required:["command"]))
            ]
        }
        result.append(MCPManager.definition); return result
    }
    public func capabilityIDs(readOnly: Bool) async -> [String] { definitions(readOnly:readOnly).map(\.name) + (await mcp.serverNames()).map { "mcp:"+$0 } }
    public func invoke(_ call: ToolCall, readOnly: Bool) async throws -> JSON { try await invoke(call,readOnly:readOnly,onUpdate:{_ in}) }
    public func invoke(_ call: ToolCall, readOnly: Bool, onUpdate: @escaping @Sendable (JSON) async -> Void) async throws -> JSON {
        try Task.checkCancellation()
        let p=call.arguments
        guard p.isObject else { throw AgentError("tool_arguments", "Tool arguments must be an object") }
        guard let definition = definitions(readOnly:readOnly).first(where:{$0.name == call.name}) else { throw AgentError("tool_unavailable", "Tool is unavailable in this session") }
        let keys=Set(definition.schema["properties"].map.keys)
        guard Set(p.map.keys).isSubset(of:keys), definition.schema["required"].list.allSatisfy({ p.map.keys.contains($0.text ?? "") }) else { throw AgentError("tool_arguments", "Missing or unsupported tool arguments") }
        if ["read", "ls", "find", "grep"].contains(call.name) {
            let files = self.files
            return try await workers.run { try files.invoke(call, cancellation: $0) }
        }
        switch call.name {
        case "mcp": return try await mcp.perform(p,readOnly:readOnly)
        case "bash":
            let command=try required(p["command"],"command",maximum:262144), timeout=try boundedInt(p["timeout"],fallback:120,maximum:600)
            guard timeout > 0 else { throw AgentError("tool_arguments", "Timeout must be positive") }
            return try await ShellRun(command:command,cwd:cwd,outputDirectory:outputs,onUpdate:onUpdate).run(timeoutSeconds:timeout)
        case "write", "edit":
            let file=try files.path(p["path"],existing:call.name == "edit"); var value: String; var previous=""
            if call.name == "write" {
                guard let content=p["content"].text, content.utf8.count <= 16*1024*1024 else { throw AgentError("tool_arguments", "Content must be text below 16 MiB") }; value=content
                previous=(try? readBounded(file,maximum:16*1024*1024)).flatMap { String(data:$0,encoding:.utf8) } ?? ""
            } else {
                let old=try required(p["oldText"],"oldText",maximum:4*1024*1024)
                guard let new=p["newText"].text, new.utf8.count <= 4*1024*1024, let existing=String(data:try readBounded(file,maximum:16*1024*1024),encoding:.utf8) else { throw AgentError("tool_arguments", "Invalid edit or non-text file") }
                let parts=existing.components(separatedBy:old)
                guard parts.count == 2 else { throw AgentError("edit_match", "oldText must match exactly once; found \(parts.count-1) matches") }
                value=parts[0]+new+parts[1]; previous=existing
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            let attributes=try? FileManager.default.attributesOfItem(atPath:file.path)
            try Data(value.utf8).write(to:file,options:.atomic)
            if let permissions=attributes?[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions:permissions],ofItemAtPath:file.path) }
            let stats=lineDiffStats(previous,value)
            var result=resultText("\(call.name == "edit" ? "Edited" : "Wrote") \(file.path) (+\(stats.added) -\(stats.removed))")
            result["stats"]=["path":JSON(file.path),"added":JSON(stats.added),"removed":JSON(stats.removed)]
            return result
        default: throw AgentError("tool_unavailable", "Unsupported tool")
        }
    }
}

/// Only immutable workspace paths cross into blocking workers. Directory
/// enumerators, file handles and regex matchers remain local to one job.
private struct FileToolContext: Sendable {
    let cwd: URL, roots: [URL]
    func path(_ value: JSON, optional: Bool = false, existing: Bool = false) throws -> URL {
        if value.isNull && optional { return cwd }
        let text=try required(value,"path")
        if text.hasPrefix("/") || text.hasPrefix("~") { return canonical(text) }
        let primary=canonical(cwd.appendingPathComponent(text).path)
        guard existing, roots.count > 1, !FileManager.default.fileExists(atPath:primary.path) else { return primary }
        let elsewhere=roots.dropFirst().map { canonical($0.appendingPathComponent(text).path) }.filter { FileManager.default.fileExists(atPath:$0.path) }
        return elsewhere.count == 1 ? elsewhere[0] : primary
    }
    func invoke(_ call: ToolCall, cancellation: BlockingWorkCancellation) throws -> JSON {
        try cancellation.checkCancellation()
        let p = call.arguments
        switch call.name {
        case "read":
            let file=try path(p["path"],existing:true), data=try readBounded(file,maximum:16 * 1024 * 1024)
            try cancellation.checkCancellation()
            guard let text=String(data:data,encoding:.utf8) else { throw AgentError("binary_file", "read accepts UTF-8 text; binary/image contents are not decoded as text") }
            let offset=try boundedInt(p["offset"],fallback:1,maximum:10_000_000), count=try boundedInt(p["limit"],fallback:2000,maximum:10_000)
            guard offset > 0, count > 0 else { throw AgentError("tool_arguments", "Line offset and limit must be positive") }
            let lines=text.components(separatedBy:"\n"), selected=lines.dropFirst(offset-1).prefix(count).joined(separator:"\n"), bounded=preview(selected,bytes:32768)
            return resultText(bounded + (offset-1+count < lines.count || bounded.utf8.count < selected.utf8.count ? "\n[Truncated. \(lines.count) total lines; read another range.]" : ""))
        case "ls":
            let directory=try path(p["path"],optional:true,existing:true), limit=try boundedInt(p["limit"],fallback:200,maximum:2000)
            let all=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey]).sorted(by:{$0.lastPathComponent < $1.lastPathComponent})
            let rows=try all.prefix(limit).map { file in
                try cancellation.checkCancellation()
                return file.lastPathComponent + ((try? file.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true ? "/" : "")
            }
            return resultText(rows.joined(separator:"\n") + (all.count > limit ? "\n[Truncated; \(all.count) entries]" : ""))
        case "find", "grep":
            let root=try path(p["path"],optional:true,existing:true), pattern=try required(p["pattern"],"pattern",maximum:4096), limit=try boundedInt(p["limit"],fallback:100,maximum:2000)
            var candidates: [URL] = []; var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath:root.path,isDirectory:&isDirectory) else { throw AgentError("missing_path", "Search path does not exist") }
            var scanTruncated=false
            if isDirectory.boolValue {
                guard let iterator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[],errorHandler:{_,_ in false}) else { throw AgentError("search_failed", "Cannot enumerate search path") }
                for case let file as URL in iterator {
                    try cancellation.checkCancellation()
                    if [".git","node_modules",".build"].contains(file.lastPathComponent) { iterator.skipDescendants(); continue }
                    if (try? file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { iterator.skipDescendants(); continue }
                    candidates.append(file)
                    if candidates.count >= 20_000 { scanTruncated=true; break }
                }
            } else { candidates=[root] }
            var hits: [String]=[]
            let options: NSRegularExpression.Options = p["ignoreCase"].flag == true ? [.caseInsensitive] : []
            let expression = call.name == "grep" ? try NSRegularExpression(pattern:p["literal"].flag == true ? NSRegularExpression.escapedPattern(for:pattern) : pattern,options:options) : nil
            for file in candidates.sorted(by:{$0.path < $1.path}) {
                try cancellation.checkCancellation()
                let relative=within(file,root) && file != root ? String(file.path.dropFirst(root.path.count+1)) : file.lastPathComponent
                if call.name == "find" {
                    if fnmatch(pattern,relative,0) == 0 || fnmatch(pattern,file.lastPathComponent,0) == 0 { hits.append(relative) }
                } else if (try? file.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) != true {
                    guard let data=try? readBounded(file,maximum:2*1024*1024), let text=String(data:data,encoding:.utf8) else { continue }
                    for (i,line) in text.components(separatedBy:"\n").enumerated() {
                        // A Foundation regex match is synchronous. Cancellation
                        // is cooperative between lines, never thread termination.
                        try cancellation.checkCancellation()
                        if expression?.firstMatch(in:line,range:NSRange(location:0,length:(line as NSString).length)) != nil { hits.append("\(relative):\(i+1): \(preview(line,bytes:1000))") }
                        if hits.count >= limit { break }
                    }
                }
                if hits.count >= limit { break }
            }
            let output=hits.joined(separator:"\n")
            return resultText(preview(output,bytes:32768) + (hits.count >= limit || scanTruncated || output.utf8.count > 32768 ? "\n[Search limited; narrow the path/pattern. Large/binary files and .git/node_modules/.build are skipped.]" : "\n[Binary and >2 MiB files, .git/node_modules/.build are skipped by grep.]"))
        default: throw AgentError("tool_unavailable", "Unsupported file tool")
        }
    }
}

func loadImages(_ attachments: [JSON]) throws -> [JSON] {
    guard attachments.count <= 4 else { throw AgentError("attachment_limit", "At most four images") }
    var result: [JSON]=[], total=0
    for item in attachments {
        let bytes=try boundedInt(item["bytes"],maximum:8*1024*1024); total += bytes
        guard bytes > 0, total <= 16*1024*1024 else { throw AgentError("attachment_limit", "Images exceed the submission limit") }
        let file=canonical(try required(item["path"],"image path")), data=try readBounded(file,maximum:8*1024*1024)
        guard data.count == bytes, sha256(data) == item["sha256"].text else { throw AgentError("attachment_changed", "Selected image changed; select it again") }
        let b=Array(data.prefix(12)); let mime: String
        if b.starts(with:[137,80,78,71,13,10,26,10]) { mime="image/png" }
        else if b.starts(with:[255,216,255]) { mime="image/jpeg" }
        else if ["GIF87a","GIF89a"].contains(String(decoding:b.prefix(6),as:UTF8.self)) { mime="image/gif" }
        else if String(decoding:b.prefix(4),as:UTF8.self) == "RIFF", String(decoding:b.suffix(4),as:UTF8.self) == "WEBP" { mime="image/webp" }
        else { throw AgentError("invalid_attachment", "Unsupported image signature") }
        guard item["mimeType"].text == mime else { throw AgentError("invalid_attachment", "MIME type and image signature differ") }
        result.append(["type":"image","mimeType":JSON(mime),"data":JSON(data.base64EncodedString())])
    }
    return result
}
