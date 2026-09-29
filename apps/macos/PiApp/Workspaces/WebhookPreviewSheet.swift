import SwiftUI

/// Chat ⋯ ▸ Preview Webhook…: the request this chat sends when it finishes,
/// made now from the chat as it is, the mini model's parameters included.
/// Send Now tries it against the address.
struct WebhookPreviewSheet: View {
    @ObservedObject var model: WorkspaceModel
    let chatID: String
    @State private var preparation: WebhookPreparation?
    @State private var preparing = false
    @State private var sending = false
    @State private var showsPrompt = false
    @State private var notice = ""
    @State private var tone: PiTone = .neutral
    /// A request asked for with Ask Again; it ends with the sheet.
    @State private var requested: Task<Void, Never>?
    @PiDismiss private var dismiss
    private var chat: ChatRecord? { model.chatRecord(chatID) }
    private var settings: WebhookSettings? { model.activeWebhook }

    var body: some View {
        PiSheet("Webhook preview", subtitle: chat?.title, symbol: "paperplane", width: 640, height: 660, cancelDisabled: sending) {
            ScrollView {
                VStack(alignment: .leading, spacing: PiSpacing.lg) {
                    if settings == nil {
                        PiNote("The webhook is off. Turn it on in Settings → Chats & notifications.", tone: .warning)
                    } else if chat?.webhookOff == true {
                        PiNote("This chat sends no webhook when it finishes; its ⋯ menu turns it back on. Send Now still sends this one.", tone: .warning)
                    }
                    if preparing {
                        HStack(spacing: PiSpacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Asking the mini model…").font(PiFont.caption).foregroundStyle(Color.piInkSecondary)
                        }
                    }
                    if let preparation { request(preparation) }
                    PiStatusLine(text: notice, tone: tone)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PiSpacing.xl)
            }
        } actions: {
            Button("Close") { dismiss() }.disabled(sending)
        } footer: {
            HStack(spacing: PiSpacing.sm) {
                Button { requested?.cancel(); requested = Task { await prepare() } } label: { Label("Ask Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.piSecondaryCompact).fixedSize()
                    .disabled(preparing || sending || settings == nil)
                    .help("Ask the mini model again and rebuild the request")
                Spacer(minLength: PiSpacing.md)
                Button(sending ? "Sending…" : "Send Now") { Task { await send() } }.buttonStyle(.piPrimary).fixedSize()
                    .disabled(preparation == nil || preparing || sending)
                    .help("Send this request to the webhook's address now")
                    .accessibilityIdentifier("webhook-preview-send")
            }
        }
        // The mini model's request belongs to the sheet: closing it ends the request.
        .task { await prepare() }
        .onDisappear { requested?.cancel() }
    }

    @ViewBuilder private func request(_ preparation: WebhookPreparation) -> some View {
        let request = preparation.request
        section("Request") {
            Text(request.method + " " + request.url.absoluteString).font(PiFont.mono).foregroundStyle(Color.piInk)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("webhook-preview-address")
        }
        if !request.headers.isEmpty {
            section("Headers") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(request.headers.enumerated()), id: \.offset) { _, header in
                        Text(header.name + ": " + header.value).font(PiFont.mono).foregroundStyle(Color.piInk)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if request.body != nil {
            section("Body") {
                Text(request.bodyText).font(PiFont.mono).foregroundStyle(Color.piInk)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("webhook-preview-body")
            }
        }
        if !request.unknown.isEmpty {
            PiNote("Nothing fills " + request.unknown.map { "{{\($0)}}" }.joined(separator: ", ") + "; sent empty.", tone: .warning)
        }
        if !preparation.parameters.isEmpty {
            section(preparation.model.map { "Written by the mini model · " + $0 } ?? "Written by the mini model") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(preparation.parameters.enumerated()), id: \.offset) { _, parameter in
                        HStack(alignment: .firstTextBaseline, spacing: PiSpacing.md) {
                            Text(parameter.name).font(PiFont.mono).foregroundStyle(Color.piInkSecondary).frame(width: 120, alignment: .leading)
                            Text(parameter.value.isEmpty ? "—" : parameter.value).font(PiFont.caption).foregroundStyle(Color.piInk)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    if let note = preparation.modelNote {
                        PiNote(note + " The chat's title stands in for title; other parameters are sent empty.", tone: .warning)
                    } else if !preparation.missing.isEmpty {
                        PiNote("The mini model left out " + preparation.missing.joined(separator: ", ") + "; the chat's title stands in for title, and the rest are sent empty.", tone: .warning)
                    }
                    if let prompt = preparation.prompt {
                        Button { withAnimation(PiMotion.quick) { showsPrompt.toggle() } } label: {
                            Label(showsPrompt ? "Hide what the mini model was asked" : "Show what the mini model was asked", systemImage: showsPrompt ? "chevron.down" : "chevron.right")
                        }
                        .buttonStyle(.piGhost).fixedSize()
                        if showsPrompt {
                            Text(prompt + (preparation.reply.map { "\n\n— Reply —\n" + $0 } ?? "")).font(PiFont.mono).foregroundStyle(Color.piInkSecondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .padding(PiSpacing.md).frame(maxWidth: .infinity, alignment: .leading).piInset(sunken: true)
                        }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PiSpacing.sm) {
            Text(title).font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
            content().padding(PiSpacing.md).frame(maxWidth: .infinity, alignment: .leading).piInset(sunken: true)
        }
    }

    private func prepare() async {
        guard let settings, !preparing else { return }
        preparing = true; notice = ""
        defer { preparing = false }
        do { preparation = try await model.prepareWebhook(for: chatID, settings: settings) }
        catch is CancellationError {}
        catch { notice = error.localizedDescription; tone = .danger }
    }

    private func send() async {
        guard let request = preparation?.request, !sending else { return }
        sending = true; notice = ""
        defer { sending = false }
        do {
            let status = try await model.deliverWebhook(request)
            notice = "Sent. \(request.url.host ?? "The address") answered HTTP \(status)."; tone = .success
        } catch {
            notice = "Not sent: " + error.localizedDescription; tone = .danger
        }
    }
}
