import Foundation

/// Merges two message lists into one sorted by id, without duplicates. On equal ids `incoming`
/// wins, which is how an edit or a re-fetched page replaces a message.
public func mergeSorted<T>(_ existing: [T], _ incoming: [T], id: (T) -> Int64) -> [T] {
    var byId: [Int64: T] = [:]
    for m in existing { byId[id(m)] = m }
    for m in incoming { byId[id(m)] = m }
    return byId.keys.sorted().map { byId[$0]! }
}

/// A conversation counts as "streaming" for a short window after each bot edit.
public struct StreamTracker<Key: Hashable> {
    public var window: TimeInterval
    private var lastEdit: [Key: Date] = [:]
    public init(window: TimeInterval = 3) { self.window = window }

    public mutating func noteEdit(_ key: Key, at date: Date = Date()) { lastEdit[key] = date }

    public func isStreaming(_ key: Key, now: Date = Date()) -> Bool {
        lastEdit[key].map { now.timeIntervalSince($0) < window } ?? false
    }
}
