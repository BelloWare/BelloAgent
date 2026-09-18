import SwiftUI

struct RenameTarget: Identifiable, Equatable { let id: String }

/// Rename a chat by hand or from three mini-model suggestions drawn from its
/// first message. Suggestions need the connection's mini model, like titles.
struct RenameChatSheet: View {
    @ObservedObject var model: WorkspaceModel
    let chatID: String
    @State private var title = ""
    @State private var suggestions: [String] = []
    @State private var suggesting = false
    @State private var notice = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    private var chat: ChatRecord? { model.record(chatID) }
    private var canSuggest: Bool { chat.flatMap { item in model.profiles.first { $0.id == item.profileID } }.map { model.titleSuggestionsAvailable(for: $0) } ?? false }

    var body: some View {
        PiSheet("Rename chat", subtitle: chat?.title, symbol: "pencil", width: 520, height: 400) {
            VStack(alignment: .leading, spacing: PiSpacing.md) {
                PiTextField(placeholder: "Chat title", text: $title, icon: "text.cursor", onSubmit: { save() })
                    .accessibilityIdentifier("sessionTitle")
                HStack {
                    Text("Suggestions").font(PiFont.micro).foregroundStyle(Color.piInkTertiary).textCase(.uppercase).tracking(0.4)
                    Spacer()
                    if suggesting { ProgressView().controlSize(.small) }
                    Button { Task { await suggest() } } label: { Label(suggestions.isEmpty ? "Suggest titles" : "Suggest again", systemImage: "sparkles") }
                        .buttonStyle(.piSecondaryCompact).disabled(suggesting || !canSuggest)
                        .help(canSuggest ? "Ask the connection's mini model for three titles" : "Suggestions need a mini model for this connection; choose one in Settings.")
                }
                if suggestions.isEmpty {
                    Text(canSuggest ? (suggesting ? "Asking the mini model…" : "The mini model reads the first message and proposes three titles.") : "Choose a mini model for this connection in Settings to get suggestions.")
                        .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 4) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            PiSelectableRow(selected: title == suggestion, action: { title = suggestion }) {
                                HStack { Text(suggestion).font(PiFont.body).foregroundStyle(Color.piInk).lineLimit(2); Spacer() }
                            }.accessibilityIdentifier("title-suggestion")
                        }
                    }
                }
                PiStatusLine(text: notice, tone: .danger)
            }.padding(PiSpacing.xl)
        } actions: {
            Button("Cancel") { dismiss() }
        } footer: {
            HStack {
                Spacer()
                Button(saving ? "Renaming…" : "Rename") { save() }.buttonStyle(.piPrimary)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            title = chat?.title ?? ""
            if canSuggest { Task { await suggest() } }
        }
    }

    private func suggest() async {
        guard !suggesting else { return }
        suggesting = true; notice = ""
        defer { suggesting = false }
        do { suggestions = try await model.suggestTitles(for: chatID) }
        catch { notice = error.localizedDescription }
    }

    private func save() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await model.setSessionTitle(chatID, title: value); dismiss() }
            catch { notice = error.localizedDescription }
        }
    }
}
