import Foundation
import Network

/// Decides WHEN the durable job queues drain. The stores themselves are
/// single-flight (a second drain request mid-pass only schedules one rerun),
/// so this only has to avoid asking twice for the same event.
///
/// Triggers:
/// - launch: AppState.bootstrap drains once after settling armed jobs.
/// - foreground: a scene going active drains, EXCEPT while the launch drain has
///   not finished (iOS reports .active right at launch, which used to drain a
///   second time on top of bootstrap's).
/// - network restored: the path going from not-satisfied to satisfied drains
///   with backoff ignored (the failures that set the backoff were the outage).
@MainActor
final class DrainCoordinator {
    private let drain: (_ ignoreBackoff: Bool) async -> Void
    private var launchDrainDone = false
    private var lastPathSatisfied: Bool?

    init(drain: @escaping (_ ignoreBackoff: Bool) async -> Void) {
        self.drain = drain
    }

    /// Bootstrap's own drain; afterwards foreground events are honored.
    func drainAtLaunch() async {
        await drain(false)
        launchDrainDone = true
    }

    /// Bootstrap ended without draining (no photo access); foreground drains
    /// may start.
    func launchWithoutDrain() {
        launchDrainDone = true
    }

    func sceneBecameActive() async {
        guard launchDrainDone else { return }
        await drain(false)
    }

    /// Every NWPath update. Only a not-satisfied -> satisfied transition
    /// drains: the first report is the current state, not news, and
    /// satisfied -> satisfied updates (interface switch) must not re-drain.
    func pathUpdated(satisfied: Bool) async {
        let was = lastPathSatisfied
        lastPathSatisfied = satisfied
        guard satisfied, was == false else { return }
        await drain(true)
    }
}

/// Where "is the network reachable" updates come from; injected so the wiring
/// is testable without a real NWPathMonitor.
protocol NetworkPathSource: AnyObject {
    /// Calls `onUpdate(satisfied)` for every path update, starting with the current state.
    @MainActor func start(onUpdate: @escaping @Sendable (_ satisfied: Bool) -> Void)
}

/// Thin NWPathMonitor wrapper; all logic lives in DrainCoordinator.pathUpdated.
final class NetworkPathWatcher: NetworkPathSource {
    private let monitor = NWPathMonitor()
    private var started = false

    /// Only `.satisfied` is reachable; `.requiresConnection` and `.unsatisfied` are not.
    static func isSatisfied(_ status: NWPath.Status) -> Bool { status == .satisfied }

    @MainActor
    func start(onUpdate: @escaping @Sendable (_ satisfied: Bool) -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in onUpdate(Self.isSatisfied(path.status)) }
        monitor.start(queue: DispatchQueue(label: "picnic.network-path"))
    }
}
