import Foundation

/// How a failed upload of a durable job (mirror, outfit, reconcile confirm)
/// must be treated.
enum JobFailureKind: Equatable {
    /// The server will never accept this job (4xx other than 408/429, or its
    /// source photo is gone). Parked as "failed", shown with Retry/Discard,
    /// never retried automatically and never dropped silently.
    case permanent
    /// The network itself failed (offline, timeout, unreachable). Every other
    /// job in the pass would fail the same way, so the pass stops here; the
    /// next trigger (network restored, foreground) retries.
    case transport
    /// 5xx, 408, 429 or anything unclassified: retry with backoff, keep going.
    case transient
}

enum JobRetryPolicy {
    static let baseBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 60 * 60

    static func classify(_ error: Error) -> JobFailureKind {
        if case MirrorClientError.badStatus(let code) = error { return classify(status: code) }
        if case OutfitClientError.badStatus(let code) = error { return classify(status: code) }
        if case OutfitClientError.assetMissing = error { return .permanent }
        if error is URLError { return .transport }
        return .transient
    }

    static func classify(status code: Int) -> JobFailureKind {
        (400..<500).contains(code) && code != 408 && code != 429 ? .permanent : .transient
    }

    /// Seconds to wait after the `attempt`-th consecutive failure (1-based):
    /// 30s, 60s, 120s ... capped at an hour.
    static func backoff(attempt: Int) -> TimeInterval {
        let exponent = Double(min(max(attempt - 1, 0), 20))
        return min(maxBackoff, baseBackoff * pow(2, exponent))
    }
}
