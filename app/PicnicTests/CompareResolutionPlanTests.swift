import XCTest
import Photos
@testable import Picnic

/// Compare's confirm must follow the deck's delete gate: a photo whose image
/// never displayed is never cued for delete.
@MainActor
final class CompareResolutionPlanTests: XCTestCase {
    typealias Q = DeckCardImagePolicy.Quality

    final class FakeAsset: PHAsset {
        var fakeID = ""
        override var localIdentifier: String { fakeID }
    }

    private func asset(_ id: String) -> FakeAsset {
        let a = FakeAsset()
        a.fakeID = id
        return a
    }

    // MARK: Pure plan

    func testSeenMembersAreDeletedAndAcceptedAreKept() {
        let plan = CompareResolutionPlan.make(
            memberIDs: ["a", "b", "c"], accepted: ["a"], rejected: [], quality: ["a": .full, "b": .full, "c": .partial]
        )
        XCTAssertEqual(plan.keptIDs, ["a"])
        XCTAssertEqual(plan.deleteIDs, ["b", "c"], "members that displayed pixels (full or low-res) are deletable")
        XCTAssertEqual(plan.protectedIDs, [])
        XCTAssertNil(plan.notice)
    }

    func testMemberThatNeverDisplayedIsNeverCuedForDelete() {
        let plan = CompareResolutionPlan.make(
            memberIDs: ["a", "b", "c", "d"], accepted: ["a"], rejected: [],
            quality: ["a": .full, "b": .none, "c": .loading]  // d never reported at all
        )
        XCTAssertEqual(plan.deleteIDs, [], "unseen members (none / loading / never reported) must not be cued for delete")
        XCTAssertEqual(plan.protectedIDs, ["b", "c", "d"])
        XCTAssertEqual(plan.keptIDs, ["a"])
    }

    func testExplicitlyRejectedButUnseenMemberIsAlsoProtected() {
        let plan = CompareResolutionPlan.make(
            memberIDs: ["a", "b"], accepted: [], rejected: ["b"], quality: ["a": .full, "b": .none]
        )
        XCTAssertEqual(plan.deleteIDs, [], "a rejected member whose image never displayed still must not be deleted")
        XCTAssertEqual(plan.protectedIDs, ["b"])
        XCTAssertEqual(plan.keptIDs, [], "with an explicit reject, unmarked members are left alone")
    }

    func testNoticeNamesTheCountAndWhy() {
        let one = CompareResolutionPlan(deleteIDs: [], keptIDs: [], protectedIDs: ["b"])
        XCTAssertEqual(one.notice, "1 photo kept — not downloaded yet. Go online to delete it.")
        let two = CompareResolutionPlan(deleteIDs: [], keptIDs: [], protectedIDs: ["b", "c"])
        XCTAssertEqual(two.notice, "2 photos kept — not downloaded yet. Go online to delete them.")
    }

    // MARK: View model (the confirm path itself)

    private func makeVM(_ ids: [String], onResolve: @escaping ([String], [String]) -> Void) -> CompareViewModel {
        CompareViewModel(
            group: CompareGroup(id: "g", assets: ids.map(asset)),
            photoLibrary: PhotoLibraryService(),
            onResolve: { toDelete, kept, _ in
                onResolve(toDelete.map(\.localIdentifier), kept.map(\.localIdentifier))
            }
        )
    }

    func testConfirmNeverHandsAnUnseenMemberToTheDeleteCallback() async {
        var deleted: [String] = [], kept: [String] = []
        let vm = makeVM(["a", "b", "c"]) { deleted = $0; kept = $1 }
        vm.imageQualityChanged("a", .full)
        vm.imageQualityChanged("b", .none)
        // c never reports
        vm.acceptedAssetIDs = ["a"]
        await vm.confirmResolution()

        XCTAssertEqual(deleted, [], "Compare confirm must not cue b (no pixels) or c (never loaded) for delete")
        XCTAssertEqual(kept, ["a"])
        XCTAssertEqual(vm.resolveNotice, "2 photos kept — not downloaded yet. Go online to delete them.",
                       "the user must be told the photos were kept")
        XCTAssertFalse(vm.isResolved, "the screen stays up until the notice is acknowledged")
        vm.acknowledgeNotice()
        XCTAssertTrue(vm.isResolved, "OK on the notice finishes the dismiss")
        XCTAssertNil(vm.resolveNotice)
    }

    func testConfirmDeletesSeenMembersAndDismissesWithoutNotice() async {
        var deleted: [String] = []
        let vm = makeVM(["a", "b", "c"]) { d, _ in deleted = d }
        vm.imageQualityChanged("a", .full)
        vm.imageQualityChanged("b", .full)
        vm.imageQualityChanged("c", .partial)
        vm.acceptedAssetIDs = ["a"]
        await vm.confirmResolution()
        XCTAssertEqual(deleted, ["b", "c"], "members that displayed are cued for delete as before")
        XCTAssertNil(vm.resolveNotice)
        XCTAssertTrue(vm.isResolved)
    }

    func testStripThumbnailCountsAsSeenAndALaterEmptyReportDoesNotUnseeIt() async {
        var deleted: [String] = []
        let vm = makeVM(["a", "b"]) { d, _ in deleted = d }
        vm.imageQualityChanged("a", .full)
        vm.imageQualityChanged("b", .partial)  // strip thumbnail displayed
        vm.imageQualityChanged("b", .none)     // page card then failed to load
        vm.acceptedAssetIDs = ["a"]
        await vm.confirmResolution()
        XCTAssertEqual(deleted, ["b"], "a member that displayed anywhere stays seen")
    }
}
