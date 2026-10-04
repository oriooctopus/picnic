import UIKit
import Network

/// Fetches one reconcile-grid thumbnail from the mirror server. Transport
/// failures and non-404 error statuses retry with capped backoff until the
/// caller's task is cancelled (the tile leaving the screen); a real 404 is
/// final. This used to give up after 3 tries and leave a grey tile forever on
/// a flaky tailnet while the server had every thumbnail.
struct RemoteThumbLoader {
    enum Outcome {
        case image(UIImage)
        /// The server answered and has no usable preview (404 or an undecodable body).
        case noPreview
    }

    var session: URLSession = .shared
    /// Waits before retry number `attempt` (1-based). Injected so tests don't sleep.
    var wait: (Int) async -> Void = { attempt in
        try? await Task.sleep(for: .seconds(min(0.5 * pow(2, Double(attempt - 1)), 8)))
    }

    /// Returns nil only when the calling task was cancelled.
    func load(_ url: URL) async -> Outcome? {
        var attempt = 0
        while !Task.isCancelled {
            if attempt > 0 {
                await wait(attempt)
                if Task.isCancelled { break }
            }
            attempt += 1
            // A thrown error is a transport failure (offline, timeout, reset):
            // retry. A cancelled task also lands here and exits via the loop test.
            guard let (data, response) = try? await session.data(from: url) else { continue }
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200:
                if let image = UIImage(data: data) { return .image(image) }
                return .noPreview
            case 404:
                return .noPreview
            default:
                continue  // 5xx/401/etc: server or auth hiccup, keep trying
            }
        }
        return nil
    }
}

/// Bumps `epoch` each time the network path becomes satisfied again, so tiles
/// still waiting on a thumbnail retry immediately instead of at the next backoff.
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    @Published private(set) var epoch = 0
    private var wasSatisfied: Bool?
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if satisfied, self.wasSatisfied == false { self.epoch += 1 }
                self.wasSatisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "picnic.connectivity"))
    }
}
