import Foundation
import Combine

/// Provides the review screen's candidate response for a month. Production
/// injects the network fetch; the DEBUG `--reconcile-seed` UI-test path
/// injects a canned response (ReconcileSeed) so the screen renders with no
/// server. A plain closure, not a protocol, because there's exactly one seam
/// and the callers are this VM's two init sites.
typealias ReconcileCandidateProvider = (String) async throws -> ReconcileResponse

/// Which of the two review sections a select-all/none action targets.
enum ReconcileSectionKind {
    case iphone
    case other
}

/// Drives the "Clean up Google" review screen: loads candidates, holds the
/// per-candidate selection, and runs the confirm → poll-results flow.
@MainActor
final class ReconcileViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded
        case confirming
        case results
        case failed(String)
    }

    let monthKey: String
    private let candidateProvider: ReconcileCandidateProvider

    @Published private(set) var state: State = .loading
    @Published private(set) var response: ReconcileResponse?
    @Published private(set) var results: ReconcileResults?
    /// Candidate ids the user wants moved to Google trash.
    @Published private(set) var selectedIds: Set<String> = []
    /// Number of on-phone assets in the manifest, for the header summary line.
    @Published private(set) var phoneAssetCount: Int = 0

    init(monthKey: String,
         candidateProvider: @escaping ReconcileCandidateProvider = { month in
             try await ReconcileClient.fetchCandidates(month: month)
         }) {
        self.monthKey = monthKey
        self.candidateProvider = candidateProvider
    }

    var selectedCount: Int { selectedIds.count }
    var iphoneCandidates: [ReconcileCandidate] { response?.sections.iphone.candidates ?? [] }
    var otherCandidates: [ReconcileCandidate] { response?.sections.other.candidates ?? [] }

    /// The "only in Google" count, for the header summary line.
    var onlyInGoogleCount: Int { response?.totalCandidates ?? 0 }

    // MARK: Load

    /// POSTs the manifest, then fetches candidates. The manifest is built by
    /// the caller (PhotoLibraryService.reconcileManifest) and passed in, so
    /// the PhotoKit work happens at presentation time in the view's `.task`
    /// rather than in this VM's init.
    func load(manifestAssets: [ReconcileManifestAsset]) async {
        state = .loading
        do {
            #if DEBUG
            // The seeded UI-test path has no server: skip the manifest POST
            // and let the injected canned provider stand in for both steps.
            let skipManifestPost = ReconcileSeed.isEnabled
            #else
            let skipManifestPost = false
            #endif
            if !skipManifestPost {
                try await ReconcileClient.postManifest(month: monthKey, assets: manifestAssets)
            }

            let fetched = try await candidateProvider(monthKey)
            response = fetched
            phoneAssetCount = manifestAssets.count
            // iPhone section pre-selected: those match photos still on this
            // phone, so trashing them is the safe default. Other section
            // pre-kept: probably not from this iPhone, don't trash without
            // review. Mirrors the design's Option A copy.
            selectedIds = Set(fetched.sections.iphone.candidates.map(\.id))
            state = .loaded
        } catch {
            state = .failed("\(error)")
        }
    }

    // MARK: Selection

    func toggle(_ candidate: ReconcileCandidate) {
        if selectedIds.contains(candidate.id) {
            selectedIds.remove(candidate.id)
        } else {
            selectedIds.insert(candidate.id)
        }
    }

    func selectAll(in section: ReconcileSectionKind) {
        for candidate in candidates(in: section) {
            selectedIds.insert(candidate.id)
        }
    }

    func deselectAll(in section: ReconcileSectionKind) {
        for candidate in candidates(in: section) {
            selectedIds.remove(candidate.id)
        }
    }

    func isSelected(_ candidate: ReconcileCandidate) -> Bool {
        selectedIds.contains(candidate.id)
    }

    private func candidates(in section: ReconcileSectionKind) -> [ReconcileCandidate] {
        guard let response else { return [] }
        switch section {
        case .iphone: return response.sections.iphone.candidates
        case .other: return response.sections.other.candidates
        }
    }

    // MARK: Confirm

    /// Sends the selected ids to the server and polls results until done.
    func confirm() async {
        let ids = Array(selectedIds)
        guard !ids.isEmpty, state != .confirming else { return }
        state = .confirming
        do {
            _ = try await ReconcileClient.confirm(month: monthKey, ids: ids)
            let final = try await pollResults()
            results = final
            state = .results
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Polls GET /results until the server reports `done`, bounded so an
    /// unreachable server can't leave the screen stuck on "confirming"
    /// forever. On cap-out, one last fetch either returns a done result or
    /// throws — there's no in-between the caller needs to special-case.
    private func pollResults() async throws -> ReconcileResults {
        for _ in 0..<30 {
            let snapshot = try await ReconcileClient.fetchResults(month: monthKey)
            if snapshot.done { return snapshot }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return try await ReconcileClient.fetchResults(month: monthKey)
    }
}
