import BackgroundTasks
import Foundation

/// The BGProcessingTask that lets `OfflineKeeper` refill the 300-photo floor
/// while the app is closed. The keeper used to run only in the foreground, so
/// nothing topped it up after photos were sorted away.
enum OfflineKeeperBackground {
    static let taskIdentifier = "com.oliverullman.picnic.offlineKeeper"
    /// Gap before iOS may start the next run: after a run the library is
    /// either full or out of photos, so asking again at once only burns budget.
    static let minimumInterval: TimeInterval = 15 * 60

    /// Pure so the request's properties are unit-tested.
    static func makeRequest(now: Date = Date()) -> BGProcessingTaskRequest {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true  // the work is iCloud downloads
        request.requiresExternalPower = false
        request.earliestBeginDate = now.addingTimeInterval(minimumInterval)
        return request
    }

    /// Must run before the app finishes launching, so PicnicApp.init calls it.
    static func register(handler: @escaping @Sendable (BGProcessingTask) -> Void) {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { fatalError("\(taskIdentifier) is not a BGProcessingTask") }
            handler(task)
        }
        if !ok { print("OfflineKeeperBackground: register FAILED for \(taskIdentifier)") }
    }

    /// Replaces any pending request. Throws on the Simulator and with Background
    /// App Refresh off; that is logged, the app works without it.
    static func schedule() {
        do {
            try BGTaskScheduler.shared.submit(makeRequest())
        } catch {
            print("OfflineKeeperBackground: submit FAILED: \(error)")
        }
    }
}
