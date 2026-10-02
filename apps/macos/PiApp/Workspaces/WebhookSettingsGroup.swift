import SwiftUI

/// Settings → Webhook: the request a chat sends when it finishes and waits
/// for its user. Saved with the rest of Settings; each chat's ⋯ menu turns it
/// off for that chat and previews it.
struct WebhookSettingsGroup: View {
    @Binding var settings: WebhookSettings
    /// Sends the webhook as typed, with a sample chat; returns the HTTP status.
    var test: ((WebhookSettings) async throws -> Int)? = nil
    @State private var testing = false
    @State private var testResult = ""
    @State private var testTone: PiTone = .neutral

    static let footer = "Sent when a chat finishes and waits for you: its run completed or failed and nothing else is queued. A run you stop sends nothing. "
        + "Placeholders: " + WebhookSettings.builtIns.map { "{{\($0)}}" }.joined(separator: ", ")
        + ", and each mini model parameter. In a JSON body they are escaped as JSON strings. "
        + "The chat's connection's mini model reads the chat's title, your last request, the assistant's output and your instructions, and writes the parameters as JSON. "
        + "A chat can turn the webhook off in its ⋯ menu, and preview it there."

    var body: some View {
        PiSettingsGroup(title: "Webhook", footer: Self.footer) {
            PiRow(label: "Send a webhook when a chat finishes", detail: "Plain http:// works for local addresses; anything else needs https://.", last: !settings.enabled) {
                Toggle("", isOn: $settings.enabled).labelsHidden()
                    .accessibilityLabel("Send a webhook when a chat finishes")
                    .accessibilityIdentifier("settings-webhook")
            }
            if settings.enabled {
                PiRow(label: "Address") {
                    PiTextField(placeholder: "https://example.com/hook", text: $settings.url, mono: true)
                        .accessibilityIdentifier("settings-webhook-url")
                }
                PiRow(label: "Method") {
                    PiDropdown(selection: $settings.method, items: WebhookSettings.methods.map { ($0, $0) }, compact: true, accessibilityName: "Webhook method")
                }
                WebhookEditorRow(label: "Headers JSON", detail: "Optional, for example {\"Authorization\": \"Bearer …\"}. Values may use placeholders.",
                                 text: $settings.headers, height: 52)
                if settings.method == "POST" {
                    WebhookEditorRow(label: "Body", detail: "Sent as JSON when it is JSON, as plain text otherwise.", text: $settings.body, height: 120)
                }
                WebhookEditorRow(label: "Mini model parameters", detail: "JSON: each name → what the mini model writes for it. Leave empty to send without asking it.",
                                 text: $settings.parameters, height: 100)
                WebhookEditorRow(label: "Instructions for the mini model", detail: "Optional: tone, language, what to point out.",
                                 text: $settings.prompt, height: 52, last: test == nil)
                if let test {
                    PiRow(label: "Try it", detail: "Sends the webhook as typed, before you save, filled from a sample chat. The parameters get sample words: no mini model is asked.", last: true) {
                        HStack(spacing: PiSpacing.sm) {
                            if testing { PiSpinner(controlSize: .small) }
                            Button { Task { await run(test) } } label: { Label(testing ? "Sending…" : "Send Test", systemImage: "paperplane") }
                                .buttonStyle(.piSecondaryCompact).fixedSize().disabled(testing)
                                .accessibilityIdentifier("settings-webhook-test")
                        }
                    }
                    if !testResult.isEmpty {
                        PiStatusLine(text: testResult, tone: testTone).padding(.horizontal, PiSpacing.lg).padding(.bottom, 10)
                            .accessibilityIdentifier("settings-webhook-test-result")
                    }
                }
            }
        }
    }
}

extension WebhookSettingsGroup {
    private func run(_ test: (WebhookSettings) async throws -> Int) async {
        testing = true; testResult = ""
        defer { testing = false }
        do {
            let status = try await test(settings)
            testResult = "Sent. \(WebhookRequest.address(settings.url, values: [:])?.host ?? "The address") answered HTTP \(status)."; testTone = .success
        } catch {
            testResult = "Not sent: " + error.localizedDescription; testTone = .danger
        }
    }
}

/// A labelled multi-line field in a settings group, as wide as the group.
private struct WebhookEditorRow: View {
    let label: String
    var detail: String? = nil
    @Binding var text: String
    var height: CGFloat
    var last = false
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(PiFont.body).foregroundStyle(Color.piInk)
                if let detail { Text(detail).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true) }
                NativeCodeEditor(text: $text, accessibilityLabel: label).frame(height: height).piInset(sunken: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PiSpacing.lg).padding(.vertical, 10)
            if !last { Rectangle().fill(Color.piHairline).frame(height: 1).padding(.leading, PiSpacing.lg) }
        }
    }
}
