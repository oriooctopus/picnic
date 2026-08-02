import SwiftUI

private struct YearGroup: Identifiable {
    let year: Int
    let months: [MonthBucket]
    var id: Int { year }
}

struct MyLifeView: View {
    @EnvironmentObject var appState: AppState
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showScrollTop = false
    @State private var selectedMonth: MonthBucket?

    private var groupedByYear: [YearGroup] {
        let grouped = Dictionary(grouping: appState.monthBuckets, by: \.year)
        return grouped.keys.sorted(by: >).map { year in
            YearGroup(year: year, months: grouped[year]!.sorted { $0.month > $1.month })
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header.id("top")

                    ForEach(groupedByYear) { entry in
                        Text(String(entry.year))
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                            ForEach(entry.months) { month in
                                MonthCardView(month: month)
                                    .environmentObject(appState)
                                    .accessibilityIdentifier("monthCard.\(month.key)")
                                    .onTapGesture { selectedMonth = month }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ScrollOffsetKey.self, value: geo.frame(in: .named("scroll")).minY)
                    }
                )
            }
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(ScrollOffsetKey.self) { value in
                showScrollTop = value < -400
            }
            .onAppear {
                scrollProxy = proxy
                appState.refreshMonths()
            }
        }
        .overlay(alignment: .bottom) {
            if showScrollTop {
                Button {
                    withAnimation { scrollProxy?.scrollTo("top", anchor: .top) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.white))
                }
                .padding(.bottom, 110)
            }
        }
        .fullScreenCover(item: $selectedMonth) { month in
            DeckView(viewModel: DeckViewModel(
                month: month,
                sortStore: appState.sortStore,
                photoLibrary: appState.photoLibrary,
                mirrorQueue: appState.mirrorQueue
            ))
            .environmentObject(appState)
            .onDisappear { appState.refreshMonths() }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Text("My life")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, Color(white: 0.18))
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                    Text("\(appState.sortStore.streakCount)").foregroundStyle(.white).bold()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color(white: 0.18)))

                Image(systemName: "gift.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Circle().fill(Color.green.opacity(0.4)))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
