import SwiftUI
import AgentCore

/// Create or clone a bot: a Hermes profile. No chat, no BotFather.
struct BotFormSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let form: BotForm
    @State private var name = ""
    @State private var summary = ""
    @State private var soul = ""
    @State private var model = ""
    @State private var source = "default"
    @State private var workdir = ""
    @State private var customTools = false
    @State private var tools: Set<String> = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(form.cloneFrom.map { "Clone \($0)" } ?? "New bot").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("lowercase-with-dashes"))
                TextField("Description", text: $summary, prompt: Text("What this bot is good at (used to route tasks)"))
                if form.cloneFrom == nil {
                    Picker("Based on", selection: $source) {
                        ForEach(store.hermes.profiles) { Text($0.name).tag($0.name) }
                    }
                }
                Picker("Model", selection: $model) {
                    Text("Same as \(form.cloneFrom ?? source)").tag("")
                    ForEach(store.hermes.models, id: \.self) { Text($0).tag($0) }
                }
                TextField("Working directory", text: $workdir, prompt: Text("Optional absolute path on the Hermes host"))
                Toggle("Choose toolsets", isOn: $customTools)
            }
            if customTools {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
                        ForEach(store.hermes.toolsets) { toolset in
                            Toggle(toolset.label, isOn: Binding(
                                get: { tools.contains(toolset.name) },
                                set: { if $0 { tools.insert(toolset.name) } else { tools.remove(toolset.name) } }))
                                .toggleStyle(.checkbox).lineLimit(1)
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
            Text(form.cloneFrom == nil ? "Role / SOUL" : "Role / SOUL (leave empty to keep the original)")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $soul).font(.body).frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("Role and system prompt")
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("Creating the profile on the Hermes host…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(form.cloneFrom == nil ? "Create" : "Clone", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValidProfileName(name) || busy)
            }
        }
        .padding(16)
        .frame(width: 480)
        .onAppear {
            // Start from what the API server platform has enabled today.
            tools = Set(store.hermes.toolsets.filter(\.enabled).map(\.name))
        }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            do {
                try await store.createBot(
                    name: name, soul: soul.trimmingCharacters(in: .whitespacesAndNewlines), model: model, description: summary,
                    toolsets: customTools ? tools.sorted() : nil, workdir: workdir.trimmingCharacters(in: .whitespaces),
                    cloneFrom: form.cloneFrom ?? (source == "default" ? nil : source))
                dismiss()
            } catch {
                self.error = describe(error)
            }
            busy = false
        }
    }
}

/// Create or edit a group: a named set of bots that share one transcript.
struct GroupFormSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let form: GroupForm
    @State private var name = ""
    @State private var members: [String] = []
    @State private var mode = "all"
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(form.group == nil ? "New group" : "Edit group").font(.headline)
            TextField("Group name", text: $name, prompt: Text("e.g. research team")).textFieldStyle(.roundedBorder)
            Picker("When nobody is @mentioned", selection: $mode) {
                Text("Everyone answers").tag("all")
                Text("Only the first member answers").tag("lead")
            }
            Text("Members (the first one leads)").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(store.hermes.profiles) { profile in
                        Toggle(isOn: Binding(
                            get: { members.contains(profile.name) },
                            set: { if $0 { members.append(profile.name) } else { members.removeAll { $0 == profile.name } } })) {
                            HStack(spacing: 6) {
                                Avatar(path: nil, title: profile.name, size: 18)
                                Text(profile.name)
                                if let position = members.firstIndex(of: profile.name) {
                                    Text(position == 0 ? "lead" : "\(position + 1)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(height: 220)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || members.isEmpty || busy)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            guard let group = form.group else { return }
            name = group.name
            members = group.members
            mode = group.mode
        }
    }

    private func submit() {
        busy = true
        error = nil
        Task {
            do {
                try await store.saveGroup(id: form.group?.id, name: name.trimmingCharacters(in: .whitespaces), members: members, mode: mode)
                dismiss()
            } catch {
                self.error = describe(error)
            }
            busy = false
        }
    }
}

struct SettingsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var bot = ""
    @State private var key = ""
    @State private var connecting = false
    @State private var confirmRestart = false
    @AppStorage("enterSends") private var enterSends = true

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Hermes").font(.headline)
            Text("Run hermes-bridge/install.sh on the Hermes host, then paste the bridge bot's @username and the key it printed. All traffic to the bot is encrypted with that key.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Bridge bot", text: $bot, prompt: Text("@your_bridge_bot"))
                SecureField("Shared key", text: $key, prompt: Text(store.hermes.isConnected ? "Stored in your Keychain" : "44 characters"))
            }
            HStack(spacing: 8) {
                Button(store.hermes.isConnected ? "Reconnect" : "Connect") {
                    connecting = true
                    Task {
                        await store.hermesConfigure(bot: bot, key: key)
                        key = ""
                        connecting = false
                    }
                }
                .disabled(bot.isEmpty || connecting || (key.isEmpty && store.bridgeBot.isEmpty))
                if store.hermes.status != .off {
                    Button("Disconnect") { store.hermesDisconnect() }
                }
                if connecting { ProgressView().controlSize(.small) }
                statusLine
            }
            if store.hermes.isConnected && !store.hermes.apiEnabled {
                Text("The Hermes API server is off, so bots cannot answer yet. On the host run: sudo ./install.sh --enable-api")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if store.hermes.isConnected {
                Button("Restart Hermes Gateway…") { confirmRestart = true }
                    .confirmationDialog("Restart the Hermes gateway?", isPresented: $confirmRestart) {
                        Button("Restart", role: .destructive) {
                            Task { if await store.hermesDo("gateway.restart", [:], timeout: 240) { store.toast = "Gateway restarting" } }
                        }
                    } message: {
                        Text("One gateway serves every bot, so this interrupts all running turns.")
                    }
            }
            Divider()
            Text("Composer").font(.headline)
            Picker("Send with", selection: $enterSends) {
                Text("↩ sends, ⇧↩ or ⌥↩ new line").tag(true)
                Text("⌘↩ sends, ↩ new line").tag(false)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            Divider()
            Text("Telegram").font(.headline)
            Toggle("Show Telegram bots and groups in the Bots list", isOn: $store.telegramSource)
            HStack {
                Button("Pin Telegram Agent…") {
                    dismiss()
                    store.showAddAgent = true
                }
                .disabled(!store.telegramSource)
                Button("Log Out of Telegram") {
                    dismiss()
                    Task { await store.logOut() }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 500)
        .onAppear { bot = store.bridgeBot.isEmpty ? "" : "@" + store.bridgeBot }
    }

    @ViewBuilder private var statusLine: some View {
        switch store.hermes.status {
        case .off: Text("Not connected").font(.caption).foregroundStyle(.secondary)
        case .connecting: Text("Handshake…").font(.caption).foregroundStyle(.secondary)
        case .connected(let version): Text("Connected · \(version)").font(.caption).foregroundStyle(.green).lineLimit(1)
        case .failed(let reason): Text(reason).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }
}
