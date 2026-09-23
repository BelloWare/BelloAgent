import SwiftUI
import AppKit

// What the Session Inspector keeps of the old message details sheet: the
// sourced model reports, the retained-body reader, and the header list.

/// Where a request's model name came from: the response body, the gateway's
/// headers, the alias asked for. Names stay literal, including provider
/// prefixes and date suffixes.
struct MessageModelReports: View {
    let attempt: [String: WireValue]
    private var modelIdentity: GatewayModelIdentity { GatewayModelIdentity(metadata: attempt) }
    var body: some View {
        let reports = modelIdentity
        VStack(alignment: .leading, spacing: 5) {
            if let response = reports.response {
                report("Response body", response)
            } else if let legacy = reports.legacyModel {
                PiKeyValue(key: "Gateway model", value: legacy, mono: true)
                Text("No sourced response-body model was recorded.").font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
            } else {
                PiKeyValue(key: "Response body", value: "Model not reported", mono: true)
            }
            ForEach(Array(reports.headerReports.enumerated()), id: \.offset) { _, value in
                report("Response header", value)
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 5) {
                    PiKeyValue(key: "Requested model", value: attempt["requestedModel"]?.string ?? "Not recorded", mono: true)
                    PiKeyValue(key: "Identity status", value: attempt["identity"]?.object?["status"]?.string ?? (reports.legacyModel == nil ? "unreported" : "reported"), mono: true)
                    ForEach(Array(reports.bodyReports.filter { $0 != reports.response }.enumerated()), id: \.offset) { _, value in
                        report("Other body report", value)
                    }
                    if reports.bodyReports.isEmpty && reports.headerReports.isEmpty {
                        let oldNames = PayloadArchive.reportedModels(attempt)
                        if !oldNames.isEmpty { PiKeyValue(key: "Legacy reports", value: oldNames.joined(separator: ", "), mono: true) }
                    }
                    Text("The displayed body name does not change routing verification or replay policy.")
                        .font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
                }.padding(.top, 4)
            } label: { Text("Routing details").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
        }
        .textSelection(.enabled)
        .accessibilityIdentifier("messageModelReports")
    }

    private func report(_ title: String, _ value: GatewayModelIdentity.Report) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            PiKeyValue(key: title, value: value.name, mono: true)
            Text(value.source).font(PiFont.micro).foregroundStyle(Color.piInkTertiary)
        }
    }
}

enum MessageBodyReader {
    static func canReadRetained(_ state: String) -> Bool { ["complete", "credential-hashed", "credential-masked", "partial", "truncated", "interrupted", "recording"].contains(state) }

    /// A stable retained prefix must be copied completely or fail explicitly;
    /// an evicted/short page is never presented as a successful whole-body copy.
    /// `length` reads a body that is still being written up to the length it
    /// had when the read began: its bytes are only ever appended, so the pages
    /// may report a longer body, never a shorter one.
    @MainActor static func assemble(limit: Int, length target: Int? = nil, progress: (Int, Int) -> Void = { _, _ in }, page: (Int) async throws -> (Data, Int)) async throws -> Data? {
        var bytes = Data(), expected: Int?
        if let target {
            guard target >= 0 else { throw HostError.failure("The capture changed while reading. Refresh and try again.") }
            guard target <= limit else { return nil }
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
            guard count <= limit else { return nil }
            expected = count
            guard chunk.count <= count - bytes.count, !chunk.isEmpty || bytes.count == count else { throw HostError.failure("The retained body is incomplete or changed while reading.") }
            bytes.append(chunk)
            progress(bytes.count, count)
            if bytes.count == count { return bytes }
        } while true
    }
}

/// Header values have already been sanitized before helper IPC and persistence.
/// Keep their presentation separate from the byte-exact body paging controls.
struct CapturedHeadersView: View {
    let headers: [String: WireValue]
    private var text: String {
        headers.keys.sorted().map { "\($0): \(headers[$0]?.string ?? headers[$0]?.pretty ?? "")" }.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Headers").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                } label: { Label("Copy headers", systemImage: "doc.on.doc") }.buttonStyle(.piGhost).disabled(headers.isEmpty)
            }
            ScrollView {
                Text(text.isEmpty ? "No headers recorded" : text).font(PiFont.mono).foregroundStyle(Color.piInkSecondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(120, CGFloat(max(1, headers.count)) * 17 + 4))
            .padding(PiSpacing.sm).piInset(sunken: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Captured HTTP headers")
    }
}
