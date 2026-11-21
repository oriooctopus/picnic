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
                Image(systemName: downloader.state == .paused ? "pause.fill" : "arrow.down")
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

/// Full-screen "Download for offline" screen. Copy is labels and data only.
struct OfflineDownloadView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var downloader: OfflineDownloader
    @Environment(\.dismiss) private var dismiss

    private var buckets: [String: MonthBucket] {
        Dictionary(uniqueKeysWithValues: appState.monthBuckets.map { ($0.key, $0) })
    }

    /// Months with something to download, grouped by year, newest first.
    private var years: [(year: Int, months: [PlanMonth])] {
        let visible = downloader.months.filter { !downloader.monthItems($0).isEmpty }
        return Dictionary(grouping: visible, by: \.year).keys.sorted(by: >).map { year in
            (year, visible.filter { $0.year == year })
        }
    }

    /// Re-run the size loader when what it needs changes.
    private var sizeTaskKey: String {
        "\(downloader.quality.rawValue)-\(downloader.includeVideos)-\(downloader.months.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 12) {
                    headerCard
                    optionsRow
                    monthList
                }
                .padding(.bottom, 130)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .bottom) { primaryButton }
        .task(id: sizeTaskKey) { await downloader.loadSizes() }
        .onAppear { downloader.refreshFreeSpace() }
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
        .padding(.top, 8).padding(.bottom, 14)
    }

    // MARK: Header card

    /// Progress stats once anything is queued or downloaded; before that the setup stats.
    private var showsProgress: Bool { downloader.state != .idle || downloader.doneCount > 0 }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sorting time")
                .font(.system(size: 13))
                .foregroundStyle(DL.secondary)
            HStack(spacing: 8) {
                ForEach([1, 3, 6, 10], id: \.self) { h in
                    let on = !downloader.manualSelection && downloader.hours == h
                    Button { downloader.chooseHours(h) } label: {
                        Text(h == 10 ? "10h+" : "\(h)h")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(on ? .black : .white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(on ? Color.white : DL.chip))
                    }
                    .accessibilityIdentifier("download.hours.\(h)")
                    .accessibilityValue(on ? "selected" : "")
                }
            }
            if showsProgress { progressStats } else { setupStats }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: DL.radius).fill(DL.card))
        .padding(.horizontal, 16)
    }

    private var setupStats: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(downloader.items.count.formatted()) photos")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text("~\(Int(downloader.pace.rounded())) / min")
                    .font(.system(size: 14))
                    .foregroundStyle(DL.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(sizeText(downloader.items))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                freeText
            }
        }
    }

    private var freeText: some View {
        Text(downloader.freeBytes.map { "\(OfflineDownloadPlan.formatBytes($0)) free" } ?? "")
            .font(.system(size: 14))
            .foregroundStyle(DL.secondary)
    }

    private var progressStats: some View {
        let done = downloader.doneCount, total = downloader.items.count
        let failed = downloader.failedCount
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(done) / \(total)")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("download.progress")
                Spacer()
                if downloader.state == .paused {
                    Text("Paused").foregroundStyle(DL.secondary)
                } else if let eta = downloader.etaMinutes {
                    Text("~\(eta) min left").foregroundStyle(DL.secondary)
                }
            }
            ProgressBar(fraction: total == 0 ? 0 : Double(done) / Double(total), height: 6)
            HStack {
                Text("\(OfflineDownloadPlan.formatDuration(minutes: OfflineDownloadPlan.readyMinutes(readyCount: done, pace: downloader.pace))) of \(downloader.hours)h ready")
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
            freeText
        }
    }

    // MARK: Quality and videos

    private var optionsRow: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    qualitySegment("Screen", .screen, id: "download.quality.screen")
                    qualitySegment("Original", .original, id: "download.quality.original")
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 12).fill(DL.chip))
                HStack(spacing: 8) {
                    Text("Videos").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Toggle("Videos", isOn: $downloader.includeVideos)
                        .labelsHidden()
                        .tint(DL.green)
                        .scaleEffect(0.8)
                        .frame(width: 44)
                        .accessibilityIdentifier("download.videos")
                }
                .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 12).fill(DL.card))
            }
            if downloader.includeVideos {
                let videos = downloader.items.filter(\.isVideo)
                Text("\(videos.count) · \(sizeText(videos))")
                    .font(.system(size: 13))
                    .foregroundStyle(DL.secondary)
            }
        }
        .padding(.horizontal, 16)
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

    // MARK: Month list

    private var monthList: some View {
        let buckets = buckets
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(years, id: \.year) { group in
                Text(String(group.year))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.top, 14).padding(.bottom, 8)
                ForEach(group.months) { month in
                    DownloadMonthRow(downloader: downloader, month: month, bucket: buckets[month.key])
                }
            }
        }
    }

    // MARK: Primary button

    private func sizeText(_ list: [OfflineDownloadPlan.Item]) -> String {
        downloader.bytes(of: list).map(OfflineDownloadPlan.formatBytes) ?? "…"
    }

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
                title = "Download \(pending.count.formatted()) photos · \(sizeText(pending))"
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
        .padding(.horizontal, 16)
        .padding(.top, 24).padding(.bottom, 16)
        .background(LinearGradient(colors: [.black, .black, .clear], startPoint: .bottom, endPoint: .top))
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

private struct DownloadMonthRow: View {
    @ObservedObject var downloader: OfflineDownloader
    let month: PlanMonth
    let bucket: MonthBucket?
    @State private var cover: UIImage?

    var body: some View {
        let list = downloader.monthItems(month)
        let done = list.filter { downloader.isDone($0.id, quality: downloader.quality) }.count
        let failed = list.filter { downloader.failed.contains($0.id) }.count
        let ready = done == list.count
        let selected = downloader.selectedKeys.contains(month.key)
        let running = downloader.state != .idle && selected && !ready
        let size = downloader.bytes(of: list)

        return Button { downloader.toggle(month.key) } label: {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(selected ? Color.white : Color(white: 0.39), lineWidth: 2)
                    .background(Circle().fill(selected ? Color.white : .clear))
                    .overlay {
                        if selected { Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.black) }
                    }
                    .frame(width: 24, height: 24)
                Group {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else {
                        Color(white: 0.15)
                    }
                }
                .frame(width: 40, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(DateFormatter().monthSymbols[month.month - 1])
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 0) {
                        Text(subtitle(count: list.count, size: ready ? nil : size))
                            .foregroundStyle(DL.secondary)
                        if failed > 0 {
                            Text(" · \(failed) failed").foregroundStyle(DL.red)
                        }
                    }
                    .font(.system(size: 14))
                    if running {
                        ProgressBar(fraction: list.isEmpty ? 0 : Double(done) / Double(list.count), height: 3)
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 8)
                if ready {
                    Text("Ready").font(.system(size: 14, weight: .semibold)).foregroundStyle(DL.green)
                } else if running {
                    Text("\(done) / \(list.count)").font(.system(size: 14)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("download.month.\(month.key)")
        .accessibilityValue([selected ? "selected" : "", ready ? "ready" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
        .task { cover = await ThumbnailLoader.thumbnail(for: bucket?.coverAsset, targetSize: CGSize(width: 120, height: 168)) }
    }

    private func subtitle(count: Int, size: Int64?) -> String {
        guard let size else { return "\(count)" }
        return "\(count) · \(OfflineDownloadPlan.formatBytes(size))"
    }
}
