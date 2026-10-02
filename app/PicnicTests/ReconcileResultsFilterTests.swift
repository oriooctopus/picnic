import XCTest
@testable import Picnic

/// Covers ReconcileViewModel.resultsForConfirm: the results screen must list
/// only the photos this confirm sent, never the month's other (kept)
/// candidates that GET /results also returns with status "candidate".
final class ReconcileResultsFilterTests: XCTestCase {

    private func entry(_ id: String, _ status: String) -> ReconcileResultEntry {
        try! JSONDecoder().decode(ReconcileResultEntry.self,
                                  from: Data(#"{"id":"\#(id)","status":"\#(status)"}"#.utf8))
    }

    func testKeptCandidatesAreNotShown() {
        let all = [entry("kept", "candidate"), entry("a", "trashed"), entry("b", "needs_review"),
                   entry("earlier", "trashed")]
        let shown = ReconcileViewModel.resultsForConfirm(all, confirmed: ["a", "b"])
        XCTAssertEqual(shown.map(\.id), ["a", "b"])
        XCTAssertEqual(shown.map(\.status), ["trashed", "needs_review"])
    }

    func testConfirmedIdMissingFromServerIsDropped() {
        let shown = ReconcileViewModel.resultsForConfirm([entry("a", "queued")], confirmed: ["a", "ghost"])
        XCTAssertEqual(shown.map(\.id), ["a"])
    }
}
