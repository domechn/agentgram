import Foundation
import TDLibKit

/// Owns the TDLib client. Updates are decoded on TDLibKit's serial per-client queue and handed
/// to the store through an ordered stream.
final class TG {
    private let manager = TDLibClientManager()
    private(set) var client: TDLibClient!
    let updates: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation

    init() {
        (updates, continuation) = AsyncStream.makeStream(of: Update.self)
        start()
    }

    /// Creates a fresh client. Called at launch and again after TDLib closes the old one
    /// (log out, credentials reset).
    func start() {
        client = manager.createClient(updateHandler: { [continuation] data, client in
            // Updates this TDLibKit version cannot decode are skipped on purpose.
            if let update = try? client.decoder.decode(Update.self, from: data) {
                continuation.yield(update)
            }
        })
        _ = try? client.execute(query: DTO(SetLogVerbosityLevel(newVerbosityLevel: 1)))
    }
}

func describe(_ error: Swift.Error) -> String {
    (error as? TDLibKit.Error)?.message ?? error.localizedDescription
}
