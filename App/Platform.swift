import AppKit
import Security
import Sparkle
import UserNotifications

/// In-app updates (Sparkle 2). The feed is the appcast.xml of the latest GitHub release; an
/// update is installed only if its archive is signed with the key in Info.plist (SUPublicEDKey).
@MainActor
enum Updater {
    static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    static var sparkle: SPUUpdater { controller.updater }

    static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    static var lastChecked: String {
        guard let date = sparkle.lastUpdateCheckDate else { return "never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "AgentGram",
         kSecAttrAccount as String: key]
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, or deletes the item when nil. Returns false if the Keychain refused.
    @discardableResult
    static func set(_ key: String, _ value: String?) -> Bool {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return true }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

/// Telegram API credentials: environment first, then Keychain. Never hardcoded.
enum Credentials {
    static func load() -> (id: Int, hash: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let id = (env["TG_API_ID"] ?? Keychain.get("api_id")).flatMap({ Int($0) }),
              let hash = env["TG_API_HASH"] ?? Keychain.get("api_hash"), !hash.isEmpty else { return nil }
        return (id, hash)
    }

    static func save(id: String, hash: String) -> Bool {
        Keychain.set("api_id", id) && Keychain.set("api_hash", hash)
    }

    static func clear() {
        Keychain.set("api_id", nil)
        Keychain.set("api_hash", nil)
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Files or image data on the pasteboard, as file URLs. Empty when it holds text, so a
    /// normal paste goes to the text view.
    static func attachments() -> [URL] {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls
        }
        guard pb.string(forType: .string) == nil,
              let tiff = NSImage(pasteboard: pb)?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return [] }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted-\(UUID().uuidString.prefix(8)).png")
        guard (try? png.write(to: url)) != nil else { return [] }
        return [url]
    }
}
