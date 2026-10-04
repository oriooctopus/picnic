import Foundation
import Combine

/// Provides the review screen's candidate response for a month. Production
/// injects the network fetch; the DEBUG `--reconcile-seed` UI-test path
/// injects a canned response (ReconcileSeed) so the screen renders with no
/// server. A plain closure, not a protocol, because there's exactly one seam
/// and the callers are this VM's two init sites.
typealias ReconcileCandidateProvider = (String) async throws -> ReconcileResponse

/// What a confirmed review will actually do. Derived from the keep set; the
/// confirm dialog shows these exact counts and `confirm` executes exactly this.
struct ReconcileDeletionPlan: Equatable {
    /// (manifest index, filename) of every phone photo to delete. The filename
    /// lets the deleter re-check the PHAsset at that index before deleting.
    let phone: [(index: Int, filename: String)]
    /// Google media keys to move to Google trash.
    let googleIds: [String]

    var isEmpty: Bool { phone.isEmpty && googleIds.isEmpty }

    static func == (lhs: ReconcileDeletionPlan, rhs: ReconcileDeletionPlan) -> Bool {
        lhs.googleIds == rhs.googleIds && lhs.phone.map(\.index) == rhs.phone.map(\.index)
    }
}

/// Thrown by the phone deleter when an asset no longer matches the manifest
/// entry the server matched it to -- nothing is deleted in that case.
struct ReconcilePhoneMismatch: Error, CustomStringConvertible {
    let index: Int
    let expected: String
    var description: String { "Phone photo #\(index) is no longer \(expected); library changed since the scan." }
}

/// Drives the unified "Clean up" review screen: loads every photo of the month
/// (on phone, in Google, or both), holds the KEEP selection (everything starts
/// kept, so doing nothing deletes nothing), and runs the delete flow: phone
/// first, then Google trash, then poll results.
@MainActor
final class ReconcileViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        /// The server's read-only Google Photos scan is still running (status
        /// "scanning" -- 33 day-searches, can take many minutes). `foundSoFar`
        /// is the candidate count the server has appended to candidates.jsonl
        /// so far, so the screen can show live progress instead of a bare
        /// spinner. MUST NOT be confused with `.loaded`'s empty state: before
        /// this fix, load() rendered whatever the first response held even
        /// while still "scanning", so a scan interrupted early looked
        /// identical to "everything already matches" (the March 2026 bug
        /// report).
        case scanning(foundSoFar: Int)
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
    /// Ids of photos the user is KEEPING. Starts as every item; unselected = delete.
    @Published private(set) var keepIds: Set<String> = []
    /// Shown on the grid after a confirm that did not run (iOS prompt declined
    /// or the library changed). Nothing was trashed from Google in that case.
    @Published private(set) var actionMessage: String?
    /// Phone photos actually deleted by the last confirm, for the results screen.
    @Published private(set) var phoneDeletedCount: Int = 0
    /// Google ids sent by the last confirm. GET /results returns EVERY
    /// candidate of the month, including ones the user kept (status
    /// "candidate"), so the results screen filters down to these.
    @Published private(set) var confirmedGoogleIds: [String] = []

    /// The results rows for what this confirm actually asked for, in the
    /// order sent. Bug 2026-10-02: unfiltered, kept photos showed up as a raw
    /// "candidate" row next to the real outcomes.
    static func resultsForConfirm(_ all: [ReconcileResultEntry], confirmed: [String]) -> [ReconcileResultEntry] {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return confirmed.compactMap { byId[$0] }
    }

    var confirmResults: [ReconcileResultEntry] {
        Self.resultsForConfirm(results?.results ?? [], confirmed: confirmedGoogleIds)
    }
    /// Number of on-phone assets in the manifest, for the header summary line.
    @Published private(set) var phoneAssetCount: Int = 0

    init(monthKey: String,
         candidateProvider: @escaping ReconcileCandidateProvider = { month in
             try await ReconcileClient.fetchCandidates(month: month)
         }) {
        self.monthKey = monthKey
        self.candidateProvider = candidateProvider
    }

    var items: [ReconcileItem] { response?.items ?? [] }
    var keepCount: Int { items.filter { keepIds.contains($0.id) }.count }
    var deleteCount: Int { items.count - keepCount }

    /// Header counts by where each photo lives.
    func count(_ source: ReconcileItem.Source) -> Int { items.filter { $0.source == source }.count }

    /// Distinct phone photos that also have a Google copy. Not count(.both):
    /// that counts Google copies, and one phone photo can match several.
    var matchedPhoneCount: Int { Set(items.filter { $0.source == .both }.compactMap(\.phoneIndex)).count }

    /// Extra Google copies of an already-matched phone photo.
    var duplicateGoogleCount: Int { count(.both) - matchedPhoneCount }

    /// Header line, e.g. "38 on phone + Google · 5 duplicates in Google · …".
    var summaryText: String {
        var parts = ["\(matchedPhoneCount) on phone + Google"]
        let dups = duplicateGoogleCount
        if dups > 0 { parts.append("\(dups) duplicate\(dups == 1 ? "" : "s") in Google") }
        parts.append("\(count(.google)) only in Google")
        parts.append("\(count(.phone)) only on phone")
        return parts.joined(separator: " · ")
    }

    /// The exact set of deletions a confirm would run.
    ///
    /// Phone: every unselected `both`/`phone` item, except that a phone photo
    /// shared by several items (two Google copies of one phone photo) is only
    /// deleted when ALL of them are unselected. Google: every unselected
    /// `both`/`google` item. When a `both` item's phone photo is kept, a
    /// sibling copy is necessarily kept too (that's what kept the phone
    /// photo), so the unselected one is a duplicate the server will trash.
    var deletePlan: ReconcileDeletionPlan {
        let doomed = items.filter { !keepIds.contains($0.id) }
        var phoneByIndex: [Int: String] = [:]
        for item in doomed where item.onPhone {
            guard let index = item.phoneIndex else { continue }
            let sharedAndKept = items.contains { $0.phoneIndex == index && keepIds.contains($0.id) }
            if !sharedAndKept { phoneByIndex[index] = item.filename }
        }
        let google = doomed.filter(\.inGoogle).map(\.id)
        let phone = phoneByIndex.keys.sorted().map { (index: $0, filename: phoneByIndex[$0]!) }
        return ReconcileDeletionPlan(phone: phone, googleIds: google)
    }

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
            let skipManifestPost = ReconcileSeed.isEnabled || ReconcileSeed.isScanningEnabled
            #else
            let skipManifestPost = false
            #endif
            if !skipManifestPost {
                try await ReconcileClient.postManifest(month: monthKey, assets: manifestAssets)
            }

            phoneAssetCount = manifestAssets.count
            try await pollUntilReady()
        } catch {
            state = .failed("\(error)")
        }
    }

    /// Polls GET /reconcile/:month until the scan reaches a terminal status.
    /// No timeout/cap on this one (unlike pollResults' 30-iteration cap for
    /// the trash pass): a scan does 33 day-searches and can legitimately run
    /// many minutes, and there's no safe "give up" value to show instead of
    /// the real result -- the bug this fixes was exactly the old code
    /// treating "haven't heard back yet" as "done, nothing found".
    private func pollUntilReady() async throws {
        while true {
            let fetched = try await candidateProvider(monthKey)
            switch fetched.status {
            case "ready":
                response = fetched
                // Everything starts KEPT: doing nothing deletes nothing.
                keepIds = Set(fetched.items.map(\.id))
                actionMessage = nil
                state = .loaded
                return
            case "failed":
                state = .failed(fetched.error ?? "The Google Photos scan failed for an unknown reason.")
                return
            default:
                // "scanning", or any value this client doesn't recognize --
                // degrade to the scanning UI rather than silently rendering
                // the (possibly still-empty) candidate lists as final.
                state = .scanning(foundSoFar: fetched.totalCandidates)
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: Selection

    func toggle(_ item: ReconcileItem) {
        if keepIds.contains(item.id) {
            keepIds.remove(item.id)
        } else {
            keepIds.insert(item.id)
        }
    }

    func keepAll() {
        keepIds = Set(items.map(\.id))
    }

    func isKept(_ item: ReconcileItem) -> Bool {
        keepIds.contains(item.id)
    }

    // MARK: Confirm

    /// Runs the confirmed plan. ORDER MATTERS:
    ///   0. The whole confirm is persisted first (ReconcileConfirmStore,
    ///      "armed") so a kill or an unreachable server after step 1 cannot
    ///      lose the Google trash request: it re-runs automatically.
    ///   1. Phone first, as ONE PhotoKit batch (`deletePhone`), so iOS shows a
    ///      single system prompt and deleted photos land in Recently Deleted.
    ///      If the user declines it (or the library changed), the call throws,
    ///      NOTHING has been deleted anywhere, the armed job is removed, and we
    ///      return to the grid with `actionMessage` set -- Google copies are
    ///      never trashed for photos that are still on the phone.
    ///   2. Then the Google trash request with the phone indexes just deleted,
    ///      which the server needs because its trash gate refuses photos that
    ///      are still on the phone.
    /// If step 2 fails after step 1 succeeded, the phone photos are gone but
    /// the job stays pending and is retried on the next launch/foreground.
    func confirm(
        queue: ReconcileConfirmStore,
        monthAssetIDs: [String],
        deletePhone: ([(index: Int, filename: String)]) async throws -> Void
    ) async {
        let plan = deletePlan
        guard !plan.isEmpty, state != .confirming else { return }
        state = .confirming
        actionMessage = nil
        let jobID: UUID
        do {
            // Resolved here, before anything is persisted or deleted: a stale
            // index must surface as ReconcilePhoneMismatch, not crash.
            let phone = try plan.phone.map { target -> (index: Int, assetID: String) in
                guard monthAssetIDs.indices.contains(target.index) else {
                    throw ReconcilePhoneMismatch(index: target.index, expected: target.filename)
                }
                return (index: target.index, assetID: monthAssetIDs[target.index])
            }
            jobID = try await queue.submit(
                month: monthKey, googleIds: plan.googleIds, phone: phone,
                deletePhone: { try await deletePhone(plan.phone) }
            )
        } catch {
            actionMessage = "Nothing was deleted. The phone deletion did not go through (\(error)); Google copies were left alone."
            state = .loaded
            return
        }
        phoneDeletedCount = plan.phone.count
        confirmedGoogleIds = plan.googleIds
        guard !plan.googleIds.isEmpty else {
            results = ReconcileResults(month: monthKey, done: true, results: [])
            state = .results
            return
        }
        do {
            try await queue.deliver(jobID)
            results = try await pollResults()
            state = .results
        } catch {
            let prefix = plan.phone.isEmpty ? "" : "Deleted \(plan.phone.count) from the phone, but "
            state = .failed("\(prefix)moving to Google trash failed: \(error). It will retry automatically.")
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
