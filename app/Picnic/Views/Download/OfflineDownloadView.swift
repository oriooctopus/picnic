import SwiftUI
import Photos

private enum DL {
    static let card = Color(white: 0.122)
    static let chip = Color(white: 0.18)
    static let segOn = Color(white: 0.353)
    static let green = Color(red: 0.19, green: 0.82, blue: 0.345)
    static let red = Color(red: 1, green: 0.41, blue: 0.38)
    static let secondary = Color.white.opacity(0.7)
    static let radius: CGFloat = 16
}

/// My Life top-bar icon: a down arrow that grows a circular progress ring while a run is active.
struct DownloadHeaderButton: View {
    @ObservedObject var downloader: OfflineDownloader
    let action: () -> Void

    private var fraction: Double {
        let total = downloader.items.count
        return total == 0 ? 0 : Double(downloader.doneCount) / Double(total)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(DL.chip)
                if downloader.state != .idle {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(DL.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                // Always the arrow, as in mockup C: the ring shows progress, and a
                // pause glyph read as "tap to pause" while the run was already paused.
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("myLife.downloadButton")
        .accessibilityLabel("Download")
    }
}

/// Full-screen "Download for offline" screen (mockup option C): a My Life style
/// month grid in select mode with a floating tray. Copy is labels and data only.
struct OfflineDownloadView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var downloader: OfflineDownloader
    @Environment(\.dismiss) private var dismiss
    @State private var sheetMonth: PlanMonth?

    private var buckets: [String: MonthBucket] {
        Dictionary(uniqueKeysWithValues: appState.monthBuckets.map { ($0.key, $0) })
    }

    /// Every month with anything in it (fully sorted ones too, dimmed), grouped by year, newest first.
    /// Months with nothing at all (no unsorted photo or video) are the "Sorted" ones.
    private var years: [(year: Int, months: [PlanMonth])] {
        let months = downloader.months
        return Set(months.map(\.year)).sorted(by: >).map { year in
            (year, months.filter { $0.year == year })
        }
    }

    /// Re-run the size loader when what it needs changes.
    private var sizeTaskKey: String {
        "\(downloader.quality.rawValue)-\(downloader.includeVideos)-\(downloader.months.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            hoursRow
            ScrollView {
                monthGrid
                    .padding(.top, 4)
                    .padding(.bottom, 16)
            }
            // safeAreaInset, not an overlay: the opaque tray reserves its own height
            // as scroll inset, so the last row is reachable at any tray height.
            .safeAreaInset(edge: .bottom, spacing: 0) { tray }
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: sizeTaskKey) { await downloader.loadSizes() }
        .onAppear { downloader.refreshFreeSpace() }
        .sheet(item: $sheetMonth) { month in
            DownloadMonthSheet(downloader: downloader, month: month, bucket: buckets[month.key])
                .presentationDetents([.medium, .large])
                .presentationBackground(Color(white: 0.09))
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Text("Download")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button { dismiss() } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(DL.chip))
            }
            .accessibilityIdentifier("download.done")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8).padding(.bottom, 8)
    }

    /// Compact sorting-time chips: they drive auto-pick (selection and trimmed last month).
    private var hoursRow: some View {
        HStack(spacing: 8) {
            Text("Sorting time")
                .font(.system(size: 12))
                .foregroundStyle(DL.secondary)
                .lineLimit(1)
                .fixedSize()
            ForEach([1, 3, 6, 10], id: \.self) { h in
                let on = !downloader.manualSelection && downloader.hours == h
                Button { downloader.chooseHours(h) } label: {
                    Text(h == 10 ? "10h+" : "\(h)h")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(on ? .black : .white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(on ? Color.white : DL.chip))
                }
                .accessibilityIdentifier("download.hours.\(h)")
                .accessibilityValue(on ? "selected" : "")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Month grid

    private var monthGrid: some View {
        let buckets = buckets
        return LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(years, id: \.year) { group in
                Text(String(group.year))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(group.months) { month in
                        DownloadMonthCard(downloader: downloader, month: month, bucket: buckets[month.key]) {
                            sheetMonth = month
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: Tray

    private func sizeText(_ list: [OfflineDownloadPlan.Item]) -> String {
        downloader.bytes(of: list).map(OfflineDownloadPlan.formatBytes) ?? "…"
    }

    private var freeText: some View {
        Text(downloader.freeBytes.map { "\(OfflineDownloadPlan.formatBytes($0)) free" } ?? "")
            .font(.system(size: 14))
            .foregroundStyle(DL.secondary)
    }

    /// Progress stats once anything is downloading or downloaded; before that the setup stats.
    private var showsProgress: Bool { downloader.state != .idle || downloader.doneCount > 0 }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsProgress { progressStats } else { setupStats }
            if downloader.state == .idle { optionsRows }
            primaryButton
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 24).fill(DL.card))
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        // Opaque black down to the physical screen edge, so the grid scrolling under the
        // tray never shows in the strip below the rounded card.
        .background(Color.black.ignoresSafeArea(edges: .bottom))
    }

    private var setupStats: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(downloader.items.count.formatted()) photos · \(sizeText(downloader.items))")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            freeText
        }
    }

    private var progressStats: some View {
        let done = downloader.doneCount, total = downloader.items.count
        let failed = downloader.failedCount
        let doneItems = downloader.items.filter { downloader.isDone($0.id, quality: downloader.quality) }
        let qualityName = downloader.quality == .screen ? "Screen" : "Original"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(done) / \(total)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("download.progress")
                Spacer()
                if downloader.state == .paused {
                    Text("Paused").foregroundStyle(DL.secondary)
                } else if let eta = downloader.etaMinutes {
                    Text("~\(eta) min left").foregroundStyle(DL.secondary)
                } else if downloader.state == .idle {
                    freeText
                }
            }
            ProgressBar(fraction: total == 0 ? 0 : Double(done) / Double(total), height: 6)
            HStack {
                Text("\(sizeText(doneItems)) / \(sizeText(downloader.items)) · \(qualityName)")
                    .foregroundStyle(DL.secondary)
                Spacer()
                if failed > 0 {
                    Button { downloader.retryFailed() } label: {
                        Text("\(failed) failed · Retry")
                            .fontWeight(.semibold)
                            .foregroundStyle(DL.red)
                    }
                    .accessibilityIdentifier("download.retry")
                }
            }
            .font(.system(size: 14))
            Text("\(OfflineDownloadPlan.formatDuration(minutes: OfflineDownloadPlan.readyMinutes(readyCount: done, pace: downloader.pace))) of \(downloader.hours)h ready")
                .font(.system(size: 13))
                .foregroundStyle(DL.secondary)
        }
    }

    // MARK: Quality and videos

    private var optionsRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                qualitySegment("Screen · \(allBytesText(.screen))", .screen, id: "download.quality.screen")
                qualitySegment("Original · \(allBytesText(.original))", .original, id: "download.quality.original")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12).fill(DL.chip))
            HStack {
                Text("Videos").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                if downloader.includeVideos {
                    let videos = downloader.items.filter(\.isVideo)
                    Text("\(videos.count) · \(sizeText(videos))")
                        .font(.system(size: 14))
                        .foregroundStyle(DL.secondary)
                }
                Spacer()
                Toggle("Videos", isOn: $downloader.includeVideos)
                    .labelsHidden()
                    .tint(DL.green)
                    .accessibilityIdentifier("download.videos")
            }
        }
    }

    /// Size of the current selection's photos at `q` (original sizes may still be loading).
    private func allBytesText(_ q: OfflineDownloader.Quality) -> String {
        let photos = downloader.items.filter { !$0.isVideo }
        if q == .screen { return OfflineDownloadPlan.formatBytes(OfflineDownloadPlan.screenBytes(photoCount: photos.count)) }
        var total: Int64 = 0
        for item in photos {
            guard let size = downloader.sizes[item.id] else { return "…" }
            total += size
        }
        return OfflineDownloadPlan.formatBytes(total)
    }

    private func qualitySegment(_ title: String, _ value: OfflineDownloader.Quality, id: String) -> some View {
        let on = downloader.quality == value
        return Button { downloader.quality = value } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? .white : DL.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9).fill(on ? DL.segOn : .clear))
        }
        .accessibilityIdentifier(id)
        .accessibilityValue(on ? "selected" : "")
    }

    // MARK: Primary button

    private var primaryButton: some View {
        let pending = downloader.items.filter { !downloader.isDone($0.id, quality: downloader.quality) }
        let title: String
        var icon: String?
        var dark = false
        var enabled = true
        var action: () -> Void = {}
        switch downloader.state {
        case .running:
            title = "Pause"; dark = true; action = { downloader.pause() }
        case .paused:
            title = "Resume"; icon = "play.fill"; action = { downloader.resume() }
        case .idle:
            if downloader.items.isEmpty == false && pending.isEmpty {
                title = "Ready"; enabled = false
            } else {
                // The setup frame's stats already say what is queued; only a partly
                // finished queue needs the remainder spelled out.
                title = showsProgress ? "Download \(pending.count.formatted()) · \(sizeText(pending))" : "Download"
                enabled = !pending.isEmpty
                action = { downloader.start() }
            }
        }
        return Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(dark ? .white : .black)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(Capsule().fill(dark ? DL.chip : Color.white))
            .opacity(enabled ? 1 : 0.4)
        }
        .disabled(!enabled)
        .accessibilityIdentifier("download.primary")
    }
}

private struct ProgressBar: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        // Fill width comes from the proportional frame, not a GeometryReader: the bar needs no measuring.
        Capsule().fill(Color(white: 0.23))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule().fill(DL.green).frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
            }
            .clipShape(Capsule())
    }
}

/// Top-right ring on a card: green arc of the month's queued items done, or a
/// full green check disc once the month is complete.
private struct MonthRing: View {
    let fraction: Double
    let complete: Bool

    var body: some View {
        ZStack {
            if complete {
                Circle().fill(DL.green)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
            } else {
                Circle().stroke(Color.white.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0.01), 1)) // a sliver so a queued month visibly has a ring
                    .stroke(DL.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(complete ? 0 : 1.5)
        .frame(width: 22, height: 22)
    }
}

/// A My Life style month card (same 2:3 cover, label gradient and corner radius as
/// MonthCardView) in select mode. Tap toggles, long press opens the month sheet.
private struct DownloadMonthCard: View {
    @ObservedObject var downloader: OfflineDownloader
    let month: PlanMonth
    let bucket: MonthBucket?
    let onLongPress: () -> Void
    @State private var cover: UIImage?

    var body: some View {
        let isSorted = month.photoIDs.isEmpty && month.videoIDs.isEmpty
        let full = OfflineDownloadPlan.items(for: month, includeVideos: downloader.includeVideos).count
        let selected = downloader.selectedKeys.contains(month.key)
        let list = downloader.monthItems(month)
        let done = list.filter { downloader.isDone($0.id, quality: downloader.quality) }.count
        let ready = !list.isEmpty && done == list.count
        // "120/310" only for a selected, partially limited month; otherwise the whole count.
        let count = selected && list.count != full ? "\(list.count)/\(full)" : "\(full)"
        let abbr = DateFormatter().shortMonthSymbols[month.month - 1]
        let selectable = full > 0

        return Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    Color(white: 0.15)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .bottom, endPoint: .top)
                        .frame(height: 64)
                        .frame(maxWidth: .infinity, alignment: .bottom)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(abbr).font(.headline).foregroundStyle(.white)
                        if isSorted {
                            Text("Sorted").font(.subheadline.bold()).foregroundStyle(.green)
                        } else {
                            Text(count).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(10)
                }
            }
            .overlay(alignment: .topLeading) {
                if selectable { selectBadge(selected).padding(8) }
            }
            .overlay(alignment: .topTrailing) {
                if selectable && (ready || selected) {
                    MonthRing(fraction: list.isEmpty ? 0 : Double(done) / Double(list.count), complete: ready)
                        .padding(8)
                }
            }
            .opacity(selectable ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { if selectable { downloader.toggle(month.key) } }
            .onLongPressGesture(minimumDuration: 0.4) { if !month.photoIDs.isEmpty { onLongPress() } }
            // One AX element per card (same reason as MonthCardView); the selection
            // state is read from the value, not from the badge.
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("download.month.\(month.key)")
            .accessibilityValue(isSorted ? "sorted" : (selected ? "selected" : ""))
            .accessibilityLabel("\(abbr), \(isSorted ? "Sorted" : count)")
            .accessibilityAddTraits(.isButton)
            .task { cover = await ThumbnailLoader.thumbnail(for: bucket?.coverAsset, targetSize: CGSize(width: 240, height: 300)) }
    }

    private func selectBadge(_ selected: Bool) -> some View {
        Circle()
            .fill(selected ? Color.white : Color.black.opacity(0.25))
            .overlay(Circle().strokeBorder(Color.white, lineWidth: selected ? 0 : 2))
            .overlay {
                if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.black) }
            }
            .frame(width: 22, height: 22)
    }
}

/// Long-press sheet: how much of one month to download. Changes apply at once.
private struct DownloadMonthSheet: View {
    @ObservedObject var downloader: OfflineDownloader
    let month: PlanMonth
    let bucket: MonthBucket?
    /// Built once: the thumbnail grid looks assets up by id for every cell.
    @State private var assets: [String: PHAsset]

    init(downloader: OfflineDownloader, month: PlanMonth, bucket: MonthBucket?) {
        self.downloader = downloader
        self.month = month
        self.bucket = bucket
        _assets = State(initialValue: Dictionary((bucket?.assets ?? []).map { ($0.localIdentifier, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    private var total: Int { month.photoIDs.count }
    /// 0 while the month is deselected, else its limit (all when none).
    private var current: Int { downloader.selectedKeys.contains(month.key) ? downloader.photoLimit(for: month) : 0 }

    private var liveText: String {
        let n = current
        let list = OfflineDownloadPlan.items(for: month, includeVideos: false, limit: n)
        let size = downloader.bytes(of: list).map(OfflineDownloadPlan.formatBytes) ?? "…"
        let time = OfflineDownloadPlan.formatSortTime(count: n, pace: downloader.pace)
        return "\(n) of \(total) · \(size) · \(time)"
    }

    var body: some View {
        let monthName = DateFormatter().monthSymbols[month.month - 1]
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(monthName) \(String(month.year))")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(total.formatted()) photos")
                        .font(.system(size: 14))
                        .foregroundStyle(DL.secondary)
                }
                Text("Photos to download")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Slider(
                    value: Binding(
                        get: { Double(current) },
                        set: { downloader.setLimit(Int($0.rounded()), for: month) }
                    ),
                    in: 0...Double(max(total, 1)), step: 1
                )
                .tint(DL.green)
                .accessibilityIdentifier("download.month.slider")
                HStack(spacing: 8) {
                    preset("25%", id: "25", count: Int((Double(total) * 0.25).rounded(.up)))
                    preset("50%", id: "50", count: Int((Double(total) * 0.5).rounded(.up)))
                    preset("All", id: "all", count: total)
                }
                Text(liveText)
                    .font(.system(size: 14))
                    .foregroundStyle(DL.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                    ForEach(Array(month.photoIDs.enumerated()), id: \.element) { index, id in
                        SheetThumb(asset: assets[id])
                            .opacity(index < current ? 1 : 0.25)
                    }
                }
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("download.month.sheet")
    }

    private func preset(_ title: String, id: String, count: Int) -> some View {
        let on = current == count
        return Button { downloader.setLimit(count, for: month) } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? .black : .white.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Capsule().fill(on ? Color.white : DL.chip))
        }
        .accessibilityIdentifier("download.month.preset.\(id)")
        .accessibilityValue(on ? "selected" : "")
    }
}

/// Small square thumbnail for the month sheet; loads lazily as the grid scrolls it in.
private struct SheetThumb: View {
    let asset: PHAsset?
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .task { image = await ThumbnailLoader.thumbnail(for: asset, targetSize: CGSize(width: 120, height: 120)) }
    }
}
