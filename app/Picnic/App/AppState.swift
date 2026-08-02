import SwiftUI
import Photos
import SwiftData

/// Root object wiring together PhotoKit access, local persistence, and the
/// mirror queue. Owned once by PicnicApp and injected as an EnvironmentObject.
@MainActor
final class AppState: ObservableObject {
    let photoLibrary = PhotoLibraryService()
    let sortStore: SortStore
    let mirrorQueue: MirrorQueueStore

    @Published var monthBuckets: [MonthBucket] = []
    // v1 placeholder profile tab always shows the red-dot badge seen in the
    // reference screenshots; there is no real notification model yet.
    @Published var hasUnviewedProfileBadge = true

    private let modelContext: ModelContext

    init() {
        modelContext = ModelContext(PersistenceController.container)
        sortStore = SortStore(context: modelContext)
        mirrorQueue = MirrorQueueStore(context: modelContext)
    }

    func bootstrap() async {
        await photoLibrary.requestAuthorization()
        guard photoLibrary.authorizationStatus == .authorized
                || photoLibrary.authorizationStatus == .limited else { return }
        refreshMonths()
        await mirrorQueue.drainQueue()
    }

    func refreshMonths() {
        monthBuckets = photoLibrary.fetchMonthBuckets()
    }
}
