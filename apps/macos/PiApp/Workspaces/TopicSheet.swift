import SwiftUI

struct TopicEditorTarget: Identifiable, Equatable {
    let projectID: String
    let topicID: String?
    var id: String { projectID + ":" + (topicID ?? "new") }
    init(projectID: String, topicID: String? = nil) {
        self.projectID = projectID; self.topicID = topicID
    }
}

/// A topic is local organization within a project; creating one neither opens
/// a session nor changes a session's working directory or model.
struct TopicSheet: View {
    @ObservedObject var model: WorkspaceModel
    let target: TopicEditorTarget
    @State private var title = ""
    @State private var saving = false
    @State private var notice = ""
    @Environment(\.dismiss) private var dismiss
    private var editing: Bool { target.topicID != nil }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        PiSheet(editing ? "Rename topic" : "New topic", subtitle: "Group related chats inside this project.", symbol: "folder", width: 480, height: 260, cancelDisabled: saving) {
            VStack(alignment: .leading, spacing: PiSpacing.md) {
                PiTextField(placeholder: "Topic name", text: $title, icon: "folder", onSubmit: save)
                    .accessibilityLabel("Topic name").accessibilityIdentifier("topicTitle")
                Text("Topics keep chats together without changing their context or project folders.")
                    .font(PiFont.caption).foregroundStyle(Color.piInkSecondary).fixedSize(horizontal: false, vertical: true)
                PiStatusLine(text: notice, tone: .danger)
            }.padding(PiSpacing.xl)
        } actions: {
            Button("Cancel") { dismiss() }.disabled(saving)
        } footer: {
            HStack {
                Spacer()
                Button(saving ? "Saving…" : editing ? "Rename" : "Create Topic", action: save)
                    .buttonStyle(.piPrimary).disabled(saving || trimmedTitle.isEmpty)
                    .accessibilityIdentifier("saveTopic")
            }
        }
        .onAppear { if let id = target.topicID { title = model.topics.first { $0.id == id }?.title ?? "" } }
    }
    private func save() {
        guard !saving, !trimmedTitle.isEmpty else { return }
        saving = true; notice = ""
        let value = trimmedTitle
        Task {
            defer { saving = false }
            do {
                if let id = target.topicID { try await model.renameTopic(id, title: value) }
                else { _ = try await model.createTopic(in: target.projectID, title: value) }
                dismiss()
            } catch { notice = error.localizedDescription }
        }
    }
}
