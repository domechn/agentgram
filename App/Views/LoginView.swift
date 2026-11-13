import SwiftUI

/// First-run API credentials, then phone → code → 2FA password.
struct LoginView: View {
    @Environment(AppStore.self) private var store
    @State private var apiId = ""
    @State private var apiHash = ""
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 40)).foregroundStyle(.tint)
            Text("AgentGram").font(.title.bold())
            switch store.auth {
            case .needCredentials:
                Text("Enter your Telegram API credentials from my.telegram.org → API development tools. They are stored in your Keychain.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                TextField("api_id", text: $apiId)
                SecureField("api_hash", text: $apiHash)
                action("Continue") { saveCredentials() }
            case .phone:
                TextField("Phone number, e.g. +14155550100", text: $phone)
                action("Send code") { await store.submit(phone: phone) }
            case .code:
                TextField("Login code", text: $code)
                action("Sign in") { await store.submit(code: code) }
            case .password(let hint):
                SecureField(hint.isEmpty ? "Two-step verification password" : "Password (hint: \(hint))", text: $password)
                action("Sign in") { await store.submit(password: password) }
            case .unsupported(let message):
                Text(message).multilineTextAlignment(.center)
            default:
                EmptyView()
            }
            if let error = localError ?? store.authError {
                Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if store.auth != .needCredentials {
                Button("Use different API credentials") {
                    Credentials.clear()
                    Task { await store.restartForNewCredentials() }
                }
                .buttonStyle(.link).font(.caption)
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(width: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(store.busy)
    }

    private func action(_ title: String, _ run: @escaping () async -> Void) -> some View {
        Button(title) { Task { await run() } }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
    }

    private func saveCredentials() {
        let id = apiId.trimmingCharacters(in: .whitespaces), hash = apiHash.trimmingCharacters(in: .whitespaces)
        guard Int(id) != nil, !hash.isEmpty else { localError = "api_id must be a number and api_hash must not be empty."; return }
        guard Credentials.save(id: id, hash: hash) else { localError = "Could not save to the Keychain."; return }
        localError = nil
        store.credentialsChanged()
    }
}
