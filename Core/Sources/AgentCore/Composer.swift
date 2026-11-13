import Foundation

public struct SlashCommand: Equatable, Identifiable {
    public var name: String // without the leading slash
    public var description: String
    public var id: String { name }
    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// The partial command being typed, or nil when the palette should be hidden.
/// Active only while the whole draft is "/" followed by non-space characters.
public func commandQuery(in draft: String) -> String? {
    guard draft.hasPrefix("/"), !draft.contains(where: { $0.isWhitespace }) else { return nil }
    return String(draft.dropFirst()).lowercased()
}

/// Prefix matches first, then substring matches, each in their original order.
public func filterCommands(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
    if query.isEmpty { return commands }
    let q = query.lowercased()
    let prefix = commands.filter { $0.name.lowercased().hasPrefix(q) }
    let inner = commands.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
    return prefix + inner
}

/// Shell-style history for the composer.
public struct InputHistory: Equatable {
    public private(set) var items: [String] = []
    private var index: Int? // position in `items` while browsing
    public init() {}

    public mutating func push(_ text: String) {
        index = nil
        guard !text.isEmpty, items.last != text else { return }
        items.append(text)
    }

    /// Browsing is allowed only when the draft is empty or is the entry currently shown,
    /// so arrow keys keep moving the caret in text the user is editing.
    private func canBrowse(_ current: String) -> Bool {
        current.isEmpty || index.map { items[$0] == current } == true
    }

    public mutating func up(current: String) -> String? {
        guard canBrowse(current), !items.isEmpty else { return nil }
        let next = current.isEmpty ? items.count - 1 : max((index ?? items.count) - 1, 0)
        index = next
        return items[next]
    }

    public mutating func down(current: String) -> String? {
        guard !current.isEmpty, canBrowse(current), let i = index else { return nil }
        if i + 1 < items.count {
            index = i + 1
            return items[i + 1]
        }
        index = nil
        return ""
    }
}
