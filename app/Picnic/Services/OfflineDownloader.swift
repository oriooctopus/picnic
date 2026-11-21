import Photos
import UIKit

/// Bulk-downloads the UNSORTED photos (and optionally videos) of chosen months
/// from iCloud into PhotoKit's on-device store, so Oliver can sort offline
/// (the deck's "Offline only" mode then finds them available).
///
/// The queue is not stored: it is always derived from (months, selection,
/// includeVideos) minus what is already done / failed / in flight. That makes
/// "selection changed mid-run" free: new months are picked up by the next
/// `pump`, deselected months' pending items simply stop being returned.
/// Items already in flight for a deselected month still finish.
///
/// Owned by AppState. `fetch` is injectable so unit tests run without PhotoKit.
@MainActor
final class OfflineDownloader: ObservableObject {
    /// Same cap as DeckPrefetcher.maxInFlight (a guess, not a measured iCloud throughput).
    static let maxInFlight = 4
    /// Completed ids are written to disk every this many completions, and on
    /// every state change. Writing per item would rewrite a multi-thousand
    /// entry JSON file thousands of times.
    static let saveEvery = 25
    /// ETA window: the throughput is measured over the last this-many completions.
    static let etaWindow = 30
    static let etaMinSamples = 5

    static let hoursKey = "offlineDownload.hours"
    static let qualityKey = "offlineDownload.quality"
    static let videosKey = "offlineDownload.videos"
    static let selectedKey = "offlineDownload.selected"
    static let manualKey = "offlineDownload.manual"
    static let limitsKey = "offlineDownload.limits"
    static let wasRunningKey = "offlineDownload.wasRunning"
    static let completedFileName = "offline-download-completed.json"

    enum Quality: String, Codable { case screen, original }
    enum RunState { case idle, running, paused }
    typealias Item = OfflineDownloadPlan.Item
    /// Downloads one item at one quality. Throws on failure.
    typealias Fetch = @Sendable (Item, Quality) async throws -> Void

    enum FetchError: Error { case assetMissing(String), incomplete(String) }

    // MARK: Settings (persisted in UserDefaults)

    @Published var hours: Int { didSet { saveSettings() } }
    @Published var quality: Quality { didSet { saveSettings() } }
    @Published var includeVideos: Bool {
        didSet { saveSettings(); rebuildItems() }
    }
    @Published private(set) var selectedKeys: Set<String> {
        didSet { saveSettings(); rebuildItems() }
    }
    /// Per-month photo limit (monthKey -> first n photos). Absent = the whole month.
    @Published private(set) var limits: [String: Int] {
        didSet { saveSettings(); rebuildItems() }
    }
    /// True once a month was toggled by hand; a chip tap clears it.
    @Published private(set) var manualSelection: Bool { didSet { saveSettings() } }

    // MARK: Plan inputs and derived queue

    @Published private(set) var months: [PlanMonth] = [] { didSet { rebuildItems() } }
    @Published private(set) var pace = OfflineDownloadPlan.defaultPace
    /// The full queue for the current selection, newest month first.
    @Published private(set) var items: [Item] = []

    // MARK: Run state

    @Published private(set) var state: RunState = .idle {
        didSet {
            defaults.set(state == .running, forKey: Self.wasRunningKey)
            // Only while running: a paused or idle download must not pin the screen on.
            UIApplication.shared.isIdleTimerDisabled = state == .running
        }
    }
    /// id -> best quality on device. Videos are stored as `.original`.
    @Published private(set) var completed: [String: Quality]
    @Published private(set) var failed: Set<String> = []
    @Published private(set) var lastError: String?
    /// Original file sizes by asset id (photos in Original mode, videos always).
    @Published private(set) var sizes: [String: Int64] = [:]
    @Published private(set) var freeBytes: Int64?

    var inFlightCount: Int { inFlight.count }

    private let fetch: Fetch
    private let defaults: UserDefaults
    private let completedURL: URL
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var unsavedCompletions = 0
    private var completionDates: [Date] = []
    /// The previous process died (or was killed) mid-run; resume at the next opportunity.
    private var interrupted: Bool

    init(
        defaults: UserDefaults = .standard,
        directory: URL = OfflineDownloader.defaultDirectory,
        fetch: Fetch? = nil,
        sizeLoader: @escaping @Sendable ([String]) -> [String: Int64] = OfflineDownloader.fileSizes
    ) {
        self.sizeLoader = sizeLoader
        self.defaults = defaults
        self.completedURL = directory.appendingPathComponent(Self.completedFileName)
        self.fetch = fetch ?? Self.defaultFetch
        hours = defaults.object(forKey: Self.hoursKey) as? Int ?? 3
        quality = Quality(rawValue: defaults.string(forKey: Self.qualityKey) ?? "") ?? .screen
        includeVideos = defaults.bool(forKey: Self.videosKey)
        selectedKeys = Set(defaults.stringArray(forKey: Self.selectedKey) ?? [])
        manualSelection = defaults.bool(forKey: Self.manualKey)
        limits = defaults.dictionary(forKey: Self.limitsKey) as? [String: Int] ?? [:]
        interrupted = defaults.bool(forKey: Self.wasRunningKey)
        // A missing file is the normal first launch; a present but unreadable one is a bug to see.
        if let data = try? Data(contentsOf: completedURL) {
            do { completed = try JSONDecoder().decode([String: Quality].self, from: data) } catch {
                completed = [:]
                lastError = "completed list unreadable: \(error)"
            }
        } else {
            completed = [:]
        }
        refreshFreeSpace()
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// `--reset-offline-download`: must run before the downloader is constructed.
    static func reset(defaults: UserDefaults = .standard, directory: URL = defaultDirectory) {
        for key in [hoursKey, qualityKey, videosKey, selectedKey, manualKey, limitsKey, wasRunningKey] {
            defaults.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(completedFileName))
    }

    // MARK: Plan inputs

    /// Called by AppState whenever the month list or sort state may have
    /// changed. An unmanual selection is re-picked while idle (so it keeps
    /// following the newest unsorted months); a run interrupted by a previous
    /// process resumes here, once months are known.
    func update(months: [PlanMonth], pace: Double) {
        self.pace = pace
        self.months = months
        if !manualSelection && state == .idle {
            applyAutoPick()
        }
        resumeIfInterrupted()
    }

    /// Foreground / launch hook: restart a run the OS interrupted, or kick the pump.
    func resumeIfInterrupted() {
        if state == .running {
            pump()
        } else if state == .idle && interrupted && !items.isEmpty {
            start()
        }
    }

    // MARK: Selection

    func chooseHours(_ h: Int) {
        hours = h
        manualSelection = false
        applyAutoPick()
    }

    /// Replaces selection AND limits: an auto-pick discards any hand-set limits.
    private func applyAutoPick() {
        let pick = OfflineDownloadPlan.autoPick(hours: hours, pace: pace, months: months, includeVideos: includeVideos)
        limits = pick.limits
        selectedKeys = pick.keys
    }

    /// "How much of this month": the first `n` photos. 0 deselects the month (and
    /// forgets the limit, so selecting it again means the whole month); n >= all is
    /// stored as no limit. Hand-set, so the selection turns manual.
    func setLimit(_ n: Int, for month: PlanMonth) {
        manualSelection = true
        if n <= 0 {
            limits[month.key] = nil
            selectedKeys.remove(month.key)
        } else {
            limits[month.key] = n >= month.photoIDs.count ? nil : n
            selectedKeys.insert(month.key)
        }
    }

    /// Photos of the month that will be downloaded: the limit when set, else all.
    func photoLimit(for month: PlanMonth) -> Int {
        min(limits[month.key] ?? month.photoIDs.count, month.photoIDs.count)
    }

    func toggle(_ monthKey: String) {
        manualSelection = true
        if selectedKeys.contains(monthKey) { selectedKeys.remove(monthKey) } else { selectedKeys.insert(monthKey) }
    }

    private func rebuildItems() {
        items = OfflineDownloadPlan.queue(months: months, selected: selectedKeys, limits: limits, includeVideos: includeVideos)
    }

    // MARK: Progress

    func isDone(_ id: String, quality q: Quality) -> Bool {
        switch completed[id] {
        case .original: return true // the original on device also satisfies the screen-size probe
        case .screen: return q == .screen
        case nil: return false
        }
    }

    var doneCount: Int { items.filter { isDone($0.id, quality: quality) }.count }
    var remainingCount: Int { items.count - doneCount }
    var failedCount: Int { items.filter { failed.contains($0.id) }.count }

    /// The month's items under its limit (what would be queued if it is selected).
    func monthItems(_ month: PlanMonth) -> [Item] {
        OfflineDownloadPlan.items(for: month, includeVideos: includeVideos, limit: limits[month.key])
    }

    /// Every unsorted item of the month is on the device at the current quality.
    func isReady(_ month: PlanMonth) -> Bool {
        let list = monthItems(month)
        return !list.isEmpty && list.allSatisfy { isDone($0.id, quality: quality) }
    }

    /// Minutes of download left from recent throughput, nil until measurable.
    var etaMinutes: Int? {
        guard state == .running, completionDates.count >= Self.etaMinSamples,
              let first = completionDates.first, let last = completionDates.last else { return nil }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return nil }
        let rate = Double(completionDates.count - 1) / span
        let pending = items.filter { !isDone($0.id, quality: quality) && !failed.contains($0.id) }.count
        return Int((Double(pending) / rate / 60).rounded(.up))
    }

    /// Total bytes of `list` at the current quality, nil while any needed size is still loading.
    func bytes(of list: [Item]) -> Int64? {
        var total: Int64 = 0
        for item in list {
            if item.isVideo || quality == .original {
                guard let size = sizes[item.id] else { return nil }
                total += size
            } else {
                total += OfflineDownloadPlan.screenBytesPerPhoto
            }
        }
        return total
    }

    func refreshFreeSpace() {
        freeBytes = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: Run control

    /// Starts (or restarts) the run over everything not yet downloaded. Clears
    /// failures: tapping Download again is the user asking for them too.
    func start() {
        interrupted = false
        failed = []
        completionDates = []
        state = .running
        pump()
    }

    /// Stops STARTING items; ones already in flight finish.
    func pause() {
        state = .paused
        saveCompleted()
    }

    func resume() {
        completionDates = []
        state = .running
        pump()
    }

    func retryFailed() {
        failed = []
        completionDates = []
        state = .running
        pump()
    }

    private func nextPending() -> Item? {
        items.first { !isDone($0.id, quality: quality) && !failed.contains($0.id) && inFlight[$0.id] == nil }
    }

    private func pump() {
        guard state == .running else { return }
        while inFlight.count < Self.maxInFlight, let item = nextPending() { launch(item) }
        if inFlight.isEmpty {
            // Nothing in flight and nothing pending: the run is over (failures stay visible).
            state = .idle
            saveCompleted()
            refreshFreeSpace()
        }
    }

    private func launch(_ item: Item) {
        let q = quality
        let fetch = self.fetch
        inFlight[item.id] = Task { @MainActor [weak self] in
            var failure: Error?
            do { try await fetch(item, q) } catch { failure = error }
            self?.finished(item, quality: q, failure: failure)
        }
    }

    private func finished(_ item: Item, quality q: Quality, failure: Error?) {
        inFlight[item.id] = nil
        if let failure {
            failed.insert(item.id)
            lastError = "\(item.id): \(failure)"
        } else {
            completed[item.id] = item.isVideo ? .original : q
            completionDates.append(Date())
            if completionDates.count > Self.etaWindow { completionDates.removeFirst() }
            unsavedCompletions += 1
            if unsavedCompletions >= Self.saveEvery { saveCompleted(); refreshFreeSpace() }
        }
        pump()
    }

    // MARK: Persistence

    private func saveSettings() {
        defaults.set(hours, forKey: Self.hoursKey)
        defaults.set(quality.rawValue, forKey: Self.qualityKey)
        defaults.set(includeVideos, forKey: Self.videosKey)
        defaults.set(Array(selectedKeys), forKey: Self.selectedKey)
        defaults.set(manualSelection, forKey: Self.manualKey)
        defaults.set(limits, forKey: Self.limitsKey)
    }

    func saveCompleted() {
        unsavedCompletions = 0
        do {
            try FileManager.default.createDirectory(at: completedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(completed).write(to: completedURL, options: .atomic)
        } catch {
            lastError = "saving completed list failed: \(error)"
        }
    }

    // MARK: Sizes

    private let sizeLoader: @Sendable ([String]) -> [String: Int64]

    /// Loads real file sizes (off the main thread, one month at a time, cached).
    /// Photos always, not only in Original mode: the tray shows "Original · <size>"
    /// next to Screen so he can compare before switching, and loading only after
    /// the switch left that label on "…" forever (seen on the phone). Videos when on.
    func loadSizes() async {
        for month in months {
            var wanted: [String] = month.photoIDs
            if includeVideos { wanted += month.videoIDs }
            wanted = wanted.filter { sizes[$0] == nil }
            if wanted.isEmpty { continue }
            let ids = wanted
            let loader = sizeLoader
            let loaded = await Task.detached(priority: .utility) { loader(ids) }.value
            sizes.merge(loaded) { _, new in new }
        }
    }

    nonisolated static func fileSizes(_ ids: [String]) -> [String: Int64] {
        var out: [String: Int64] = [:]
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            out[asset.localIdentifier] = BestPhotoResolver.fileSize(for: asset)
        }
        return out
    }

    // MARK: Real fetch

    static var defaultFetch: Fetch {
        #if DEBUG
        // `--simulate-offline-download`: succeed after ~800 ms with no PhotoKit,
        // so UI tests can watch a whole run on the simulator. Was 150 ms, which
        // finished the 35-photo seed library before the test could capture the
        // mid-run state; 800 ms x 35 / 4 in flight is ~7 s.
        if ProcessInfo.processInfo.arguments.contains("--simulate-offline-download") {
            return { _, _ in try await Task.sleep(nanoseconds: 800_000_000) }
        }
        #endif
        return { item, quality in try await fetchReal(item, quality) }
    }

    nonisolated static func fetchReal(_ item: Item, _ quality: Quality) async throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil).firstObject else {
            throw FetchError.assetMissing(item.id)
        }
        if item.isVideo {
            try await fetchVideo(asset)
        } else if quality == .screen {
            try await fetchScreen(asset)
        } else {
            try await fetchOriginal(asset)
        }
    }

    /// Exactly the request DeckPrefetcher.start makes (shared options and
    /// completeness test), so a finished download turns the offline probe to "yes".
    private nonisolated static func fetchScreen(_ asset: PHAsset) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var didResume = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: ThumbnailLoader.screenPixelSize, contentMode: .aspectFit,
                options: DeckPrefetcher.screenDownloadOptions()
            ) { image, info in
                guard !didResume else { return }
                didResume = true
                if DeckPrefetcher.isCompleteScreenImage(image, info) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: FetchError.incomplete(asset.localIdentifier))
                }
            }
        }
    }

    /// Pulls the full original; the bytes are discarded, PhotoKit keeps them on disk.
    private nonisolated static func fetchOriginal(_ asset: PHAsset) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            var didResume = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                guard !didResume else { return }
                didResume = true
                if data != nil && info?[PHImageErrorKey] == nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: FetchError.incomplete(asset.localIdentifier))
                }
            }
        }
    }

    /// .highQualityFormat with network on downloads the whole video (the
    /// deck's own playback uses .automatic, which may stream instead); same
    /// AVAsset request LocalAvailability's video probe uses with the network off.
    private nonisolated static func fetchVideo(_ asset: PHAsset) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            var didResume = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard !didResume else { return }
                didResume = true
                if avAsset != nil && info?[PHImageErrorKey] == nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: FetchError.incomplete(asset.localIdentifier))
                }
            }
        }
    }
}
