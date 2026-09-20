import SwiftUI

/// First-launch flow: connect a LiteLLM gateway, choose a model, open a workspace.
struct OnboardingView: View {
    @ObservedObject var model: WorkspaceModel
    @StateObject private var setup = OnboardingState()
    @State private var filter = ""
    @State private var folderError = ""
    private var step: Int { setup.step.rawValue }
    private var filteredModels: [String] { filter.isEmpty ? setup.models : setup.models.filter { $0.localizedCaseInsensitiveContains(filter) } }
    private var selectedWorkspace: WorkspaceRecord? { model.workspaces.first { $0.id == model.selectedWorkspaceID } }
    var body: some View {
        ScrollView {
            VStack(spacing: PiSpacing.xl) {
                VStack(spacing: 10) {
                    Image("BelloAgentIcon").resizable().interpolation(.high).scaledToFit().frame(width: 72, height: 72).accessibilityHidden(true)
                    Text(setup.resumedFromSaved ? "Welcome back" : "Welcome to Bello Agent").font(PiFont.display(30)).foregroundStyle(Color.piInk)
                    Text(setup.resumedFromSaved ? "Your connection is saved. Choose a project and start a chat." : "Three quick steps: connect your LiteLLM gateway, pick a model, open a project.")
                        .font(PiFont.body).foregroundStyle(Color.piInkSecondary)
                }
                steps
                VStack(alignment: .leading, spacing: PiSpacing.lg) {
                    switch step {
                    case 0: gateway
                    case 1: modelStep
                    default: workspace
                    }
                }
                .padding(PiSpacing.xl).frame(maxWidth: .infinity, alignment: .leading)
                .piElevated(radius: PiRadius.lg)
                .animation(.easeInOut(duration: 0.22), value: step)
                .animation(.easeInOut(duration: 0.22), value: selectedWorkspace)
                PiStatusLine(text: setup.message, tone: setup.message.hasPrefix("Saved") ? .success : .danger)
            }
            .frame(maxWidth: 600).padding(.vertical, 48).padding(.horizontal, PiSpacing.xl).frame(maxWidth: .infinity)
        }
        .background(Color.piContent)
        .disabled(setup.busy)
        .safeAreaInset(edge: .bottom) {
            if setup.testingConnection {
                Button("Cancel Connection Test") { setup.cancelConnectionTest() }.buttonStyle(.piSecondary).padding(PiSpacing.md)
            }
        }
        .task {
            setup.resume(profiles: model.profiles, preferredID: model.profileChoice)
            if model.profiles.contains(where: { $0.id == setup.profile.id }) { model.profileChoice = setup.profile.id }
            if model.selectedWorkspaceID == nil { model.selectedWorkspaceID = model.workspaces.first(where: \.trusted)?.id }
        }
        .onChange(of: setup.profile.baseUrl) { _, _ in setup.invalidateModelList() }
        .onChange(of: setup.profile.api) { _, _ in setup.invalidateModelList() }
        .onChange(of: setup.profile.catalogUrl) { _, _ in setup.invalidateModelList() }
        .onChange(of: setup.key) { _, _ in setup.invalidateModelList() }
        .onDisappear { setup.invalidateModelList(); setup.cancelConnectionTest() }
    }

    private var steps: some View {
        HStack(spacing: 0) {
            ForEach(Array(["Gateway", "Model", "Project"].enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(index <= step ? Color.piAccent : Color.piFillStrong).frame(width: 22, height: 22)
                        if index < step { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.piOnAccent) }
                        else { Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(index == step ? Color.piOnAccent : Color.piInkSecondary) }
                    }
                    Text(title).font(.system(size: 12.5, weight: index == step ? .semibold : .regular)).foregroundStyle(index == step ? Color.piInk : Color.piInkSecondary)
                }
                if index < 2 { Rectangle().fill(index < step ? Color.piAccent : Color.piHairlineStrong).frame(height: 1).frame(maxWidth: 60).padding(.horizontal, PiSpacing.md) }
            }
        }.animation(.easeInOut(duration: 0.22), value: step)
    }

    private var gateway: some View {
        Group {
            PiSectionHeader("Connect your LiteLLM gateway", subtitle: "The key is stored in your macOS Keychain and is only sent to this gateway.")
            field("Connection name") { PiTextField(placeholder: "Team router", text: $setup.profile.name) }
            field("Gateway URL") { PiTextField(placeholder: "https://litellm.example.com", text: $setup.profile.baseUrl, icon: "link", mono: true) }
            field("API key") { PiTextField(placeholder: "sk-…", text: $setup.key, icon: "key", secure: true) }
            field("Custom model catalog URL · optional") { PiTextField(placeholder: "Blank uses the Bello model catalog", text: Binding(get: { setup.profile.catalogUrl ?? "" }, set: { setup.profile.catalogUrl = $0.isEmpty ? nil : $0 }), icon: "list.bullet.rectangle", mono: true) }
            Text("The Bello model catalog is included. Set a URL to replace it with your own list, context sizes and reasoning levels. External catalogs are fetched anonymously.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            if setup.hasStoredKey { PiNote("Leave the key empty to keep its saved value. Re-enter it only to refresh a custom catalog on the gateway's origin.") }
            field("API") { Text("Responses").font(PiFont.body).foregroundStyle(Color.piInkSecondary) }
            HStack(alignment: .center) {
                // A disabled Continue always says what it is waiting for.
                if !setup.gatewayHint.isEmpty { PiNote(setup.gatewayHint).accessibilityIdentifier("onboarding-gateway-hint") }
                Spacer()
                Button { setup.step = .model; Task { await setup.listModels() } } label: { Label("Continue", systemImage: "arrow.right") }.labelStyle(.trailingIcon).buttonStyle(.piPrimary).disabled(!setup.gatewayReady)
            }
            .animation(.easeInOut(duration: 0.18), value: setup.gatewayHint)
        }
    }

    private var modelStep: some View {
        Group {
            PiSectionHeader("Choose a model", subtitle: "Catalog choices set the model's context and output ceiling. Your output budget stays separate. The gateway must support the selected alias.") {
                if setup.listing { ProgressView().controlSize(.small) } else { Button { Task { await setup.listModels() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.piGhost) }
            }
            if !setup.listError.isEmpty { PiNote(setup.listError, tone: .warning) }
            if !setup.models.isEmpty {
                PiTextField(placeholder: "Filter models", text: $filter, icon: "magnifyingglass")
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredModels, id: \.self) { id in
                            let item = setup.descriptors.first { $0.id == id }
                            PiSelectableRow(selected: setup.profile.modelId == id, action: { if let item { setup.choose(item) } else { setup.profile.modelId = id } }) {
                                HStack(spacing: PiSpacing.sm) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item?.displayName ?? id).font(item == nil ? PiFont.mono : PiFont.heading).foregroundStyle(Color.piInk)
                                            if let item, item.displayName != item.id { Text(item.id).font(PiFont.mono).foregroundStyle(Color.piInkSecondary) }
                                            if let context = item?.contextLabel { PiBadge(text: context) }
                                            if let output = item?.outputLimitLabel { PiBadge(text: output) }
                                            if let efforts = item?.reasoning, !efforts.isEmpty { PiBadge(text: "effort " + efforts.joined(separator: "/"), icon: "brain") }
                                        }
                                        if let text = item?.description, !text.isEmpty { Text(text).font(PiFont.caption).foregroundStyle(Color.piInkSecondary).lineLimit(2) }
                                    }
                                    Spacer()
                                    if setup.profile.modelId == id { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.piAccent) }
                                }
                            }
                        }
                    }.padding(4)
                }.frame(height: min(220, CGFloat(max(1, filteredModels.count)) * 34 + 8)).piInset(sunken: true)
            } else if setup.listing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading the model catalog…").font(PiFont.caption).foregroundStyle(Color.piInkSecondary) }
            }
            field("Model or router alias") { PiTextField(placeholder: "gpt-5.1 or claude-router", text: $setup.profile.modelId, icon: "cpu", mono: true) }
            HStack(spacing: PiSpacing.md) {
                field("Context capacity") { PiNumberField(placeholder: "Tokens", value: $setup.profile.contextWindow, width: 130) }
                field("Output budget") { PiNumberField(placeholder: "Tokens", value: $setup.profile.maxOutputTokens, width: 130) }
                Spacer()
            }
            Text("The output budget only sizes the reserve the context estimate keeps for a reply; it is never sent as a limit. Model output ceiling: " + (setup.profile.modelOutputLimit.map { "\($0.formatted()) tokens, sent with every request." } ?? "not supplied, so requests carry no output limit."))
                .font(PiFont.caption).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { setup.invalidateModelList(); setup.step = .gateway } label: { Label("Back", systemImage: "arrow.left") }.buttonStyle(.piGhost)
                Spacer()
                Button { Task { await save() } } label: { Label(setup.saving ? "Saving…" : "Save and Continue", systemImage: "arrow.right") }.labelStyle(.trailingIcon).buttonStyle(.piPrimary)
                    .disabled(setup.profile.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || setup.saving)
            }
        }
    }

    private var workspace: some View {
        Group {
            if selectedWorkspace?.trusted == true {
                PiSectionHeader("Start your first chat", subtitle: "Your project is ready. Test & Start sends one small request to the selected model, then opens the chat. Add more folders below if a task spans several.")
            } else {
                PiSectionHeader("Create a project", subtitle: "Choose the primary folder Bello Agent may read, then add more folders if a task spans several. Editing chats can also run commands and change files there with your permissions.")
            }
            if let workspace = selectedWorkspace {
                WorkspaceFolderList(model: model, workspace: workspace) { folderError = $0 }
                    .transition(AnyTransition.move(edge: .top).combined(with: .opacity))
                PiStatusLine(text: folderError, tone: .danger)
            }
            PiNote("Test & Start sends one small request to the selected model. Tools and project contents are excluded. Gateway usage may be charged; you can inspect the request in Requests.")
            Text("Request and response bodies are saved locally for 30 days by default, within the storage quota. Authentication headers are masked. Change capture and retention in Settings.").font(PiFont.caption).foregroundStyle(Color.piInkTertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { setup.step = .model } label: { Label("Back", systemImage: "arrow.left") }.buttonStyle(.piGhost)
                Spacer()
                Button { folderError = ""; model.pickWorkspace() } label: { Label(selectedWorkspace == nil ? "Choose Primary Folder…" : "Change Primary Folder…", systemImage: "house") }
                    .buttonStyle(.piSecondary)
                if selectedWorkspace?.trusted == true {
                    Button {
                        let verifiedWorkspace = selectedWorkspace
                        Task {
                            await setup.finish(hasTrustedWorkspace: selectedWorkspace?.trusted == true,
                                               verifyConnection: { try await model.verifyOnboardingConnection($0) }) {
                                guard model.profileChoice == setup.profile.id,
                                      selectedWorkspace == verifiedWorkspace else { throw ConnectionProbeError.changed }
                                try await model.createOnboardingChat()
                            }
                        }
                    } label: {
                        Label(setup.testingConnection ? "Testing Connection…" : setup.finishing ? "Starting…" : "Test & Start Chat", systemImage: "arrow.right")
                    }.labelStyle(.trailingIcon).buttonStyle(.piPrimary)
                }
            }
        }
    }

    private func field<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(PiFont.micro).foregroundStyle(Color.piInkSecondary).textCase(.uppercase).tracking(0.4)
            control()
        }
    }

    private func save() async {
        let saved = await setup.save { profile, key in
            try await model.saveProfile(profile, key: key)
            guard let saved = model.profiles.first(where: { $0.id == model.profileChoice }) else {
                throw HostError.failure("The saved connection could not be reloaded. Reload Settings before continuing.")
            }
            return saved
        }
        if saved, model.selectedWorkspaceID == nil { model.selectedWorkspaceID = model.workspaces.first(where: \.trusted)?.id }
    }
}
