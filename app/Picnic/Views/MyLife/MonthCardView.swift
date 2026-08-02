import SwiftUI
import Photos

struct MonthCardView: View {
    @EnvironmentObject var appState: AppState
    let month: MonthBucket

    @State private var coverImage: UIImage?

    private var remainingCount: Int {
        max(0, month.assets.count - appState.sortStore.addressedCount(for: month.assets))
    }

    private var isSorted: Bool {
        appState.sortStore.isMonthManuallySorted(month.key) || (month.assets.isEmpty == false && remainingCount == 0)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(white: 0.15))

            if let coverImage {
                Image(uiImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .bottom, endPoint: .top)
                .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 2) {
                Text(month.monthAbbreviation)
                    .font(.headline)
                    .foregroundStyle(.white)
                if isSorted {
                    Text("Sorted").font(.subheadline.bold()).foregroundStyle(.green)
                } else {
                    Text("\(remainingCount)").font(.subheadline).foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(10)
        }
        .aspectRatio(0.78, contentMode: .fit)
        .contextMenu {
            Button {
                appState.sortStore.setMonthManuallySorted(true, monthKey: month.key)
            } label: {
                Label("Mark as sorted", systemImage: "hand.thumbsup.fill")
            }
            Button {
                appState.sortStore.setMonthManuallySorted(false, monthKey: month.key)
            } label: {
                Label("Mark as unsorted", systemImage: "circle")
            }
        }
        .task {
            coverImage = await ThumbnailLoader.thumbnail(for: month.coverAsset, targetSize: CGSize(width: 240, height: 300))
        }
    }
}
