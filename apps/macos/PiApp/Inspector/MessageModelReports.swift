import AppKit

/// Literal, sourced gateway names; routing verification remains independent
/// of the response body's display name.
@MainActor final class MessageModelReports: DashView, PiKit.WidthSizing {
    private(set) var attempt: [String: WireValue] = [:]
    private let column = ShellStack(.vertical, spacing: 5)
    private let details = ShellStack(.vertical, spacing: 5, padding: NSEdgeInsets(top: 4, left: 17, bottom: 0, right: 0))
    let disclosure = MessageRoutingDisclosure()
    private lazy var routing = ShellStack(.vertical, spacing: 0, [.view(disclosure), .view(details, .fill)])
    private var expanded = false
    init(attempt: [String: WireValue]) {
        super.init(frame: .zero); addSubview(column)
        disclosure.setAccessibilityRole(.disclosureTriangle); disclosure.setAccessibilityValue(false)
        disclosure.onPress = { [weak self] in self?.toggleDetails() }
        details.isHidden = true
        update(attempt: attempt)
        setAccessibilityIdentifier("messageModelReports")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    /// Live request metadata can change without resetting the reader's
    /// disclosure or removing the focused disclosure control.
    func update(attempt: [String: WireValue]) {
        guard self.attempt != attempt || column.items.isEmpty else { return }
        self.attempt = attempt
        let reports = GatewayModelIdentity(metadata: attempt)
        var rows: [ShellItem] = []
        if let response = reports.response { rows.append(.view(Self.report("Response body", response), .fill)) }
        else if let legacy = reports.legacyModel {
            rows += [.view(PiKit.KeyValue(key: "Gateway model", value: legacy, mono: true), .fill),
                     .view(Self.micro("No sourced response-body model was recorded."), .fill)]
        } else { rows.append(.view(PiKit.KeyValue(key: "Response body", value: "Model not reported", mono: true), .fill)) }
        for value in reports.headerReports { rows.append(.view(Self.report("Response header", value), .fill)) }
        details.items = [.view(PiKit.KeyValue(key: "Requested model", value: attempt["requestedModel"]?.string ?? "Not recorded", mono: true), .fill),
                         .view(PiKit.KeyValue(key: "Identity status", value: attempt["identity"]?.object?["status"]?.string ?? (reports.legacyModel == nil ? "unreported" : "reported"), mono: true), .fill)]
        for value in reports.bodyReports where value != reports.response { details.items.append(.view(Self.report("Other body report", value), .fill)) }
        if reports.bodyReports.isEmpty && reports.headerReports.isEmpty {
            let old = PayloadArchive.reportedModels(attempt)
            if !old.isEmpty { details.items.append(.view(PiKit.KeyValue(key: "Legacy reports", value: old.joined(separator: ", "), mono: true), .fill)) }
        }
        details.items.append(.view(Self.micro("The displayed body name does not change routing verification or replay policy."), .fill))
        rows.append(.view(routing, .fill)); column.items = rows
        column.relayoutAll(); PiKit.sizeChanged(self)
    }
    private static func micro(_ text: String) -> ShellSelectableText { ShellSelectableText(text, font: PiKit.Font.micro, color: .piInkTertiary) }
    private static func report(_ title: String, _ value: GatewayModelIdentity.Report) -> NSView {
        ShellStack(.vertical, spacing: 1, [.view(PiKit.KeyValue(key: title, value: value.name, mono: true), .fill), .view(micro(value.source), .fill)])
    }
    private func toggleDetails() {
        expanded.toggle(); details.isHidden = !expanded
        disclosure.expanded = expanded
        disclosure.setAccessibilityValue(expanded); column.relayoutAll(); PiKit.sizeChanged(self)
    }
    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 700)) }
    override func layout() { super.layout(); column.frame = bounds }
}

@MainActor final class MessageRoutingDisclosure: PiKit.ButtonBase {
    var expanded = false { didSet { redrawContent() } }
    private var line: PiKit.Line { PiKit.Line("Routing details", font: PiKit.Font.caption, color: .piInkSecondary) }
    private var glyph: PiKit.Symbol { PiKit.Symbol(expanded ? "chevron.down" : "chevron.right", size: 10, weight: .semibold) }
    init() { super.init(frame: .zero); pressScales = false; setAccessibilityLabel("Routing details") }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    override var intrinsicContentSize: NSSize { let words = line.size(scale: piScale); return NSSize(width: 12 + words.width, height: max(glyph.layoutSize.height, words.height) + 8) }
    override func styleFace() { fill.backgroundColor = CGColor.clear; stroke.borderColor = CGColor.clear }
    override func drawContent(in rect: CGRect) {
        glyph.draw(centredIn: CGRect(x: 0, y: 0, width: 8, height: rect.height), color: .tertiaryLabelColor, scale: piScale)
        line.draw(in: CGRect(x: 12, y: 0, width: max(0, rect.width - 12), height: rect.height), scale: piScale)
    }
}

enum MessageBodyReader {
    static func canReadRetained(_ state: String) -> Bool { ["complete", "credential-hashed", "credential-masked", "partial", "truncated", "interrupted", "recording"].contains(state) }

    /// A stable retained prefix must be copied completely or fail explicitly;
    /// an evicted/short page is never presented as a successful whole-body copy.
    /// `length` reads a body that is still being written up to the length it
    /// had when the read began: its bytes are only ever appended, so the pages
    /// may report a longer body, never a shorter one.
    @MainActor static func assemble(length target: Int? = nil, progress: (Int, Int) -> Void = { _, _ in }, page: (Int) async throws -> (Data, Int)) async throws -> Data {
        var bytes = Data(), expected: Int?
        if let target {
            guard target >= 0 else { throw HostError.failure("The capture changed while reading. Refresh and try again.") }
            while bytes.count < target {
                try Task.checkCancellation()
                let (chunk, count) = try await page(bytes.count)
                try Task.checkCancellation()
                guard count >= target, expected.map({ count >= $0 }) ?? true else { throw HostError.failure("The capture changed while reading. Refresh and try again.") }
                expected = count
                let wanted = min(chunk.count, target - bytes.count)
                guard wanted > 0 else { throw HostError.failure("The retained body is incomplete or changed while reading.") }
                bytes.append(chunk.prefix(wanted))
                progress(bytes.count, target)
            }
            return bytes
        }
        repeat {
            try Task.checkCancellation()
            let (chunk, count) = try await page(bytes.count)
            try Task.checkCancellation()
            guard count >= 0, expected == nil || expected == count else { throw HostError.failure("The capture changed while reading. Refresh and try again.") }
            expected = count
            guard chunk.count <= count - bytes.count, !chunk.isEmpty || bytes.count == count else { throw HostError.failure("The retained body is incomplete or changed while reading.") }
            bytes.append(chunk)
            progress(bytes.count, count)
            if bytes.count == count { return bytes }
        } while true
    }
}

/// Sanitized headers stay separate from byte-exact body controls.
@MainActor final class CapturedHeadersView: DashView, PiKit.WidthSizing {
    let headers: [String: WireValue]
    let text: String
    private let title = PiKit.TextLine(PiKit.Line("Headers", font: PiKit.Font.caption, color: .piInkSecondary))
    let copy = PiKit.Button("Copy headers", symbol: "doc.on.doc", style: .ghost)
    private let column: ShellStack
    init(headers: [String: WireValue]) {
        self.headers = headers
        text = headers.keys.sorted().map { "\($0): \(headers[$0]?.string ?? headers[$0]?.pretty ?? "")" }.joined(separator: "\n")
        let value = ShellSelectableText(text.isEmpty ? "No headers recorded" : text, font: PiKit.Font.mono, color: .piInkSecondary)
        let scroll = PayloadScroll(value)
        let viewport = PayloadViewport(scroll, height: min(120, CGFloat(max(1, headers.count)) * 17 + 4))
        column = ShellStack(.vertical, spacing: 5, [.view(ShellStack(.horizontal, spacing: PiSpacing.sm, [.view(title), .spacer(8), .view(copy)]), .fill),
                                                   .view(PiKit.inset(ShellStack(.vertical, spacing: 0, padding: NSEdgeInsets(top: PiSpacing.sm, left: PiSpacing.sm, bottom: PiSpacing.sm, right: PiSpacing.sm), [.view(viewport, .fill)]), sunken: true), .fill)])
        super.init(frame: .zero); addSubview(column)
        copy.isEnabled = !headers.isEmpty
        copy.onPress = { [weak self] in
            guard let self else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.text, forType: .string)
        }
        setAccessibilityElement(false); setAccessibilityRole(.group); setAccessibilityLabel("Captured HTTP headers")
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func height(forWidth width: CGFloat) -> CGFloat { column.height(forWidth: width) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 700)) }
    override func layout() { super.layout(); column.frame = bounds }
}
