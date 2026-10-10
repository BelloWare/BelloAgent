// belloperf: external, app-agnostic macOS measurements for Swift-vs-Rust comparisons.
//
// It never reads app data. It spawns an executable with an explicit environment,
// observes its windows through the window server, samples CPU/memory of its whole
// process tree, and can post synthetic input to that process only.
//
// Clocks: all times are CLOCK_UPTIME_RAW (ProcessInfo.systemUptime), in ms.
// "window" = first on-screen layer-0 window owned by the process tree.
// "settled" = last frame change touching >= 0.5% of pixels before a 1.5 s quiet
//   period (small changes such as a blinking caret are ignored).
// Screen-image change latency measures window-server composited images
// (CGWindowListCreateImage), i.e. presented-to-window-server, not physical scanout.

import AppKit
import CoreGraphics
import Darwin
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func now() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
func die(_ message: String) -> Never { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); exit(2) }

// MARK: process tree accounting

func childPIDs(_ pid: pid_t) -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 256)
    let bytes = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    guard bytes > 0 else { return [] }
    return Array(buffer.prefix(Int(bytes))).filter { $0 > 0 }
}

func processTree(_ root: pid_t) -> [pid_t] {
    var result: [pid_t] = [root]; var queue: [pid_t] = [root]
    while let next = queue.popLast() {
        for child in childPIDs(next) where !result.contains(child) { result.append(child); queue.append(child) }
    }
    return result
}

struct Usage { var cpuNs: UInt64 = 0; var footprint: UInt64 = 0; var lifetimeMaxFootprint: UInt64 = 0; var resident: UInt64 = 0; var count = 0 }

func usage(_ pids: [pid_t]) -> Usage {
    var total = Usage()
    for pid in pids {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { continue }
        total.cpuNs += info.ri_user_time + info.ri_system_time
        total.footprint += info.ri_phys_footprint
        total.lifetimeMaxFootprint += info.ri_lifetime_max_phys_footprint
        total.resident += info.ri_resident_size
        total.count += 1
    }
    return total
}

// mach absolute units -> ns
let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func machToNs(_ value: UInt64) -> UInt64 { value * UInt64(timebase.numer) / UInt64(timebase.denom) }

// MARK: windows

struct WindowInfo { let id: CGWindowID; let pid: pid_t; let bounds: CGRect; let name: String? }

func windows(of pids: [pid_t]) -> [WindowInfo] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    var found: [WindowInfo] = []
    for entry in list {
        guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, pids.contains(owner),
              (entry[kCGWindowLayer as String] as? Int) == 0,
              ((entry[kCGWindowAlpha as String] as? Double) ?? 0) > 0,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.width >= 200, bounds.height >= 150,
              let number = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
        found.append(WindowInfo(id: number, pid: owner, bounds: bounds, name: entry[kCGWindowName as String] as? String))
    }
    return found
}

// Downscaled grayscale-ish signature of a window image for change detection.
final class Frame {
    let width: Int, height: Int; var bytes: [UInt8]
    init(width: Int, height: Int) {
        self.width = max(1, width); self.height = max(1, height)
        bytes = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }
    convenience init?(window: CGWindowID, crop: CGRect? = nil, scale: Int = 2) {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, window, [.boundsIgnoreFraming, .nominalResolution]) else { return nil }
        var source = image
        if let crop, let cropped = image.cropping(to: crop) { source = cropped }
        self.init(width: source.width / scale, height: source.height / scale)
        let width = self.width, height = self.height
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }
    /// Fraction of pixels whose max channel delta exceeds 24/255.
    func changed(from other: Frame) -> Double {
        guard other.width == width, other.height == height else { return 1 }
        var count = 0
        bytes.withUnsafeBufferPointer { a in other.bytes.withUnsafeBufferPointer { b in
            var i = 0
            while i < a.count {
                let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i+1]) - Int(b[i+1])), abs(Int(a[i+2]) - Int(b[i+2])))
                if d > 24 { count += 1 }
                i += 4
            }
        } }
        return Double(count) / Double(width * height)
    }
    var nonBackgroundFraction: Double {
        // Fraction of pixels differing from the most common corner color.
        let r = bytes[0], g = bytes[1], b = bytes[2]; var count = 0
        var i = 0
        while i < bytes.count { if abs(Int(bytes[i]) - Int(r)) + abs(Int(bytes[i+1]) - Int(g)) + abs(Int(bytes[i+2]) - Int(b)) > 30 { count += 1 }; i += 4 }
        return Double(count) / Double(width * height)
    }
}

// MARK: launch measurement

struct Options {
    var label = "app"; var trials = 5; var cold = false; var idleSeconds = 30.0; var settleQuietMs = 1500.0
    var maxWaitMs = 60_000.0; var out: String? = nil; var env: [String: String] = [:]; var exe = ""; var args: [String] = []
    var workDir: String? = nil; var primeRuns = 1; var quitTimeout = 15.0
}

func parse(_ argv: ArraySlice<String>) -> Options {
    var o = Options(); var it = argv.makeIterator()
    while let a = it.next() {
        switch a {
        case "--label": o.label = it.next()!
        case "--trials": o.trials = Int(it.next()!)!
        case "--cold": o.cold = true
        case "--idle": o.idleSeconds = Double(it.next()!)!
        case "--quiet": o.settleQuietMs = Double(it.next()!)!
        case "--max-wait": o.maxWaitMs = Double(it.next()!)!
        case "--out": o.out = it.next()!
        case "--prime": o.primeRuns = Int(it.next()!)!
        case "--cwd": o.workDir = it.next()!
        case "--env": let kv = it.next()!; let parts = kv.split(separator: "=", maxSplits: 1).map(String.init); o.env[parts[0]] = parts.count > 1 ? parts[1] : ""
        case "--": o.exe = it.next()!; while let rest = it.next() { o.args.append(rest) }
        default: die("unknown argument \(a)")
        }
    }
    if o.exe.isEmpty { die("missing -- <exe> [args]") }
    return o
}

func purgeCaches() {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo"); p.arguments = ["-n", "/usr/sbin/purge"]
    try? p.run(); p.waitUntilExit()
    if p.terminationStatus != 0 { die("sudo purge failed") }
    Thread.sleep(forTimeInterval: 2)
}

func gracefulQuit(_ process: Process, timeout: Double) -> String {
    let pid = process.processIdentifier
    if let app = NSRunningApplication(processIdentifier: pid) { app.terminate() }
    else { kill(pid, SIGTERM) }
    let deadline = now() + timeout * 1000
    while process.isRunning && now() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if !process.isRunning { return "quit" }
    kill(pid, SIGTERM); let deadline2 = now() + 5000
    while process.isRunning && now() < deadline2 { Thread.sleep(forTimeInterval: 0.05) }
    if !process.isRunning { return "sigterm" }
    kill(pid, SIGKILL); process.waitUntilExit(); return "sigkill"
}

func runLaunchTrial(_ o: Options, index: Int, measured: Bool) -> [String: Any] {
    if o.cold && measured { purgeCaches() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: o.exe); process.arguments = o.args
    var environment = ProcessInfo.processInfo.environment; for (k, v) in o.env { environment[k] = v }
    process.environment = environment
    if let workDir = o.workDir { process.currentDirectoryURL = URL(fileURLWithPath: workDir) }
    let devnull = FileHandle(forWritingAtPath: "/dev/null"); process.standardOutput = devnull; process.standardError = devnull
    var result: [String: Any] = ["trial": index, "measured": measured, "cold": o.cold && measured]
    let t0 = now()
    do { try process.run() } catch { result["error"] = "spawn: \(error)"; return result }
    let pid = process.processIdentifier
    var windowAt: Double? = nil; var window: WindowInfo? = nil
    while now() - t0 < o.maxWaitMs {
        if !process.isRunning { result["error"] = "exited early status=\(process.terminationStatus)"; return result }
        if let w = windows(of: processTree(pid)).first { windowAt = now(); window = w; break }
        Thread.sleep(forTimeInterval: 0.004)
    }
    guard let windowAt, let window else { result["error"] = "no window"; _ = gracefulQuit(process, timeout: o.quitTimeout); return result }
    result["windowMs"] = windowAt - t0
    result["windowSize"] = [window.bounds.width, window.bounds.height]
    // Visual settle.
    var last: Frame? = nil; var lastBigChange = windowAt; var firstContent: Double? = nil; var frames = 0; var bigChanges = 0
    var captureCostTotal = 0.0
    while now() - lastBigChange < o.settleQuietMs && now() - t0 < o.maxWaitMs {
        let c0 = now()
        guard let frame = Frame(window: window.id) else { Thread.sleep(forTimeInterval: 0.01); continue }
        captureCostTotal += now() - c0; frames += 1
        if firstContent == nil && frame.nonBackgroundFraction > 0.01 { firstContent = c0 }
        if let last { if frame.changed(from: last) >= 0.005 { lastBigChange = c0; bigChanges += 1 } } else { lastBigChange = c0 }
        last = frame
        Thread.sleep(forTimeInterval: 0.008)
    }
    result["firstContentMs"] = firstContent.map { $0 - t0 } as Any
    result["settledMs"] = lastBigChange - t0
    result["settleFrames"] = frames; result["settleBigChanges"] = bigChanges
    result["meanCaptureMs"] = frames > 0 ? captureCostTotal / Double(frames) : 0
    if measured {
        // Idle: from settle+2s for idleSeconds.
        Thread.sleep(forTimeInterval: 2)
        let tree0 = processTree(pid); let u0 = usage(tree0); let w0 = now()
        var peakFootprint = u0.footprint; var samples: [[Double]] = []
        while now() - w0 < o.idleSeconds * 1000 {
            Thread.sleep(forTimeInterval: 1)
            let u = usage(processTree(pid)); peakFootprint = max(peakFootprint, u.footprint)
            samples.append([now() - w0, Double(machToNs(u.cpuNs)) / 1e6, Double(u.footprint) / 1048576])
        }
        let tree1 = processTree(pid); let u1 = usage(tree1); let w1 = now()
        let cpuMs = Double(machToNs(u1.cpuNs &- u0.cpuNs)) / 1e6
        result["idleCpuPercent"] = cpuMs / (w1 - w0) * 100
        result["footprintMB"] = Double(u1.footprint) / 1048576
        result["residentMB"] = Double(u1.resident) / 1048576
        result["idlePeakFootprintMB"] = Double(peakFootprint) / 1048576
        result["lifetimeMaxFootprintMB"] = Double(u1.lifetimeMaxFootprint) / 1048576
        result["processes"] = tree1.count
        result["totalCpuMsAtEnd"] = Double(machToNs(u1.cpuNs)) / 1e6
        result["idleSamples"] = samples
    }
    result["quit"] = gracefulQuit(process, timeout: o.quitTimeout)
    return result
}

func summarize(_ values: [Double]) -> [String: Double] {
    guard !values.isEmpty else { return [:] }
    let s = values.sorted(); func pct(_ p: Double) -> Double { s[min(s.count - 1, max(0, Int(ceil(Double(s.count) * p)) - 1))] }
    let mean = s.reduce(0, +) / Double(s.count)
    return ["n": Double(s.count), "min": s.first!, "p50": pct(0.5), "p90": pct(0.9), "max": s.last!, "mean": mean]
}

func commandLaunch(_ argv: ArraySlice<String>) {
    let o = parse(argv)
    var trials: [[String: Any]] = []
    for i in 0..<o.primeRuns { let r = runLaunchTrial(o, index: -1 - i, measured: false); print("prime \(r)") ; trials.append(r) }
    for i in 0..<o.trials {
        let r = runLaunchTrial(o, index: i, measured: true)
        var brief = r; brief.removeValue(forKey: "idleSamples"); print("\(o.label) trial \(i): \(brief)")
        trials.append(r)
        Thread.sleep(forTimeInterval: 1)
    }
    let measured = trials.filter { ($0["measured"] as? Bool) == true && $0["error"] == nil }
    var summary: [String: Any] = [:]
    for key in ["windowMs", "firstContentMs", "settledMs", "idleCpuPercent", "footprintMB", "residentMB", "lifetimeMaxFootprintMB"] {
        summary[key] = summarize(measured.compactMap { $0[key] as? Double })
    }
    let report: [String: Any] = ["label": o.label, "exe": o.exe, "args": o.args, "envKeys": Array(o.env.keys).sorted(), "cold": o.cold,
                                 "idleSeconds": o.idleSeconds, "trials": trials, "summary": summary,
                                 "failures": trials.filter { $0["error"] != nil }.count,
                                 "host": ProcessInfo.processInfo.operatingSystemVersionString, "generatedUptimeMs": now()]
    print("SUMMARY \(o.label): \(summary)")
    if let out = o.out {
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: out))
    }
}

// MARK: input latency
//
// belloperf input --pid PID --kind key|wheel --region x,y,w,h [--click x,y] [--count N]
//                 [--interval-ms M] [--wheel-px P] [--out FILE] [--label L]
// Region/click are screen points with a top-left origin (CoreGraphics). One event
// per sample; latency = post time -> first window-server image change of the region.
// Input is posted only while the target is the frontmost application.

func frontmostPID() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

func regionImage(window: CGWindowID, rect: CGRect) -> Frame? {
    guard let image = CGWindowListCreateImage(rect, .optionIncludingWindow, window, [.boundsIgnoreFraming, .nominalResolution]) else { return nil }
    return Frame(image: image)
}

extension Frame {
    convenience init?(image: CGImage) {
        self.init(width: image.width, height: image.height)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }
}

func postKey(_ keyCode: CGKeyCode, character: String?, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)!
        event.flags = flags
        if let character { let units = Array(character.utf16); event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
        event.post(tap: .cghidEventTap)
    }
}

func postClick(_ point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
}

func postWheel(_ pixels: Int32, at point: CGPoint) {
    let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0)!
    event.location = point
    event.post(tap: .cghidEventTap)
}

func commandInput(_ argv: ArraySlice<String>) {
    var pid: pid_t = 0, kind = "key", region = CGRect.zero, click: CGPoint? = nil, count = 40, interval = 0.35, wheel: Int32 = -60
    var out: String? = nil, label = "input", timeout = 2000.0, text: [Character]? = nil
    var it = argv.makeIterator()
    func nums(_ s: String) -> [Double] { s.split(separator: ",").map { Double($0)! } }
    while let a = it.next() {
        switch a {
        case "--pid": pid = pid_t(it.next()!)!
        case "--kind": kind = it.next()!
        case "--region": let v = nums(it.next()!); region = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        case "--click": let v = nums(it.next()!); click = CGPoint(x: v[0], y: v[1])
        case "--count": count = Int(it.next()!)!
        case "--interval-ms": interval = Double(it.next()!)! / 1000
        case "--wheel-px": wheel = Int32(it.next()!)!
        case "--timeout-ms": timeout = Double(it.next()!)!
        case "--out": out = it.next()!
        case "--label": label = it.next()!
        case "--text": text = Array(it.next()!)
        default: die("unknown argument \(a)")
        }
    }
    guard let window = windows(of: processTree(pid)).max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { die("no window for pid \(pid)") }
    NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateIgnoringOtherApps])
    Thread.sleep(forTimeInterval: 0.6)
    guard frontmostPID() == window.pid else { die("target is not frontmost; refusing to post input") }
    if let click { postClick(click); Thread.sleep(forTimeInterval: 0.4) }
    let center = CGPoint(x: region.midX, y: region.midY)
    if kind == "wheel" { CGWarpMouseCursorPosition(center); Thread.sleep(forTimeInterval: 0.2) }
    var samples: [Double] = []; var timeouts = 0; var captures: [Int] = []
    let letters = Array("abcdefghijklmnopqrstuvwxyz")
    let keyCodes: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
    for index in 0..<count {
        Thread.sleep(forTimeInterval: interval)
        guard frontmostPID() == window.pid else { print("target lost focus; stopping at sample \(index)"); break }
        guard let before = regionImage(window: window.id, rect: region) else { continue }
        let t0 = now()
        if kind == "key" {
            let source = text ?? letters
            let c = source[index % source.count]; postKey(keyCodes[c] ?? 0, character: String(c))
        } else {
            postWheel(index % 2 == 0 ? wheel : -wheel, at: center)
        }
        var done = false; var polls = 0
        while now() - t0 < timeout {
            polls += 1
            if let frame = regionImage(window: window.id, rect: region), frame.changed(from: before) > 0 { samples.append(now() - t0); done = true; break }
        }
        captures.append(polls)
        if !done { timeouts += 1 }
    }
    let summary = summarize(samples)
    print("SUMMARY \(label): \(summary) timeouts=\(timeouts)")
    if let out {
        let report: [String: Any] = ["label": label, "kind": kind, "region": [region.minX, region.minY, region.width, region.height], "samplesMs": samples,
                                     "timeouts": timeouts, "pollsPerSample": captures, "summary": summary, "windowSize": [window.bounds.width, window.bounds.height]]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
    }
}

// MARK: resource sampling
// belloperf sample --pid PID --seconds S [--exclude PID,...] [--out FILE] [--label L]
// Per-second CPU (% of one core) and physical footprint of the process tree.
func commandSample(_ argv: ArraySlice<String>) {
    var pid: pid_t = 0, seconds = 30.0, out: String? = nil, label = "sample", exclude: Set<pid_t> = []
    var it = argv.makeIterator()
    while let a = it.next() {
        switch a {
        case "--pid": pid = pid_t(it.next()!)!
        case "--seconds": seconds = Double(it.next()!)!
        case "--out": out = it.next()!
        case "--label": label = it.next()!
        case "--exclude": exclude = Set(it.next()!.split(separator: ",").map { pid_t($0)! })
        default: die("unknown argument \(a)")
        }
    }
    func tree() -> [pid_t] { processTree(pid).filter { !exclude.contains($0) } }
    var previous = usage(tree()); var previousAt = now(); let start = previousAt
    var rows: [[Double]] = []; var peak = Double(previous.footprint) / 1048576
    while now() - start < seconds * 1000 {
        Thread.sleep(forTimeInterval: 1)
        let u = usage(tree()); let t = now()
        let cpu = Double(machToNs(u.cpuNs &- previous.cpuNs)) / 1e6 / (t - previousAt) * 100
        let mb = Double(u.footprint) / 1048576; peak = max(peak, mb)
        rows.append([(t - start) / 1000, cpu, mb, Double(u.count)])
        previous = u; previousAt = t
    }
    let cpus = rows.map { $0[1] }; let mbs = rows.map { $0[2] }
    let summary: [String: Any] = ["cpuPercent": summarize(cpus), "footprintMB": summarize(mbs), "peakFootprintMB": peak]
    print("SUMMARY \(label): \(summary)")
    if let out {
        let report: [String: Any] = ["label": label, "pid": pid, "seconds": seconds, "rows[t,cpu%,footprintMB,processes]": rows, "summary": summary]
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
    }
}

// MARK: window info
func commandWindows(_ argv: ArraySlice<String>) {
    let pid = pid_t(argv.first!)!
    for w in windows(of: processTree(pid)) { print("window id=\(w.id) pid=\(w.pid) bounds=\(w.bounds)") }
}

func commandCapture(_ argv: ArraySlice<String>) {
    let a = Array(argv); let id = CGWindowID(a[0])!
    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]) else { die("no image") }
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest); print("\(image.width)x\(image.height)")
}

let argv = CommandLine.arguments
guard argv.count >= 2 else { die("usage: belloperf launch|input|windows|capture ...") }
switch argv[1] {
case "launch": commandLaunch(argv.dropFirst(2))
case "input": commandInput(argv.dropFirst(2))
case "windows": commandWindows(argv.dropFirst(2))
case "capture": commandCapture(argv.dropFirst(2))
case "sample": commandSample(argv.dropFirst(2))
default: die("unknown command \(argv[1])")
}
