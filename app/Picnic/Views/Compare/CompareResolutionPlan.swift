import Foundation

/// Which members of a Compare group a confirm deletes, keeps, or leaves alone,
/// as pure values so the delete gate is testable without PHAssets.
///
/// Same rule as the deck (`DeckCardImagePolicy.blockDeleteWithoutLocalImage`):
/// a photo whose image never displayed is never cued for delete, because the
/// user would be deleting something they could not see. Compare is stricter
/// than the deck about `.loading`: the deck never locks a card that is merely
/// slow, but Compare's "keep these, lose the rest" sweeps members the user may
/// never have looked at, so only a member with pixels on screen is deletable.
struct CompareResolutionPlan: Equatable {
    var deleteIDs: [String]
    var keptIDs: [String]
    /// Would have been cued for delete, but their image never displayed. They
    /// stay unsorted (neither deleted nor marked kept) so they come back in the deck.
    var protectedIDs: [String]

    static func make(
        memberIDs: [String],
        accepted: Set<String>,
        rejected: Set<String>,
        quality: [String: DeckCardImagePolicy.Quality]
    ) -> CompareResolutionPlan {
        let deleteUnmarked = rejected.isEmpty
        var plan = CompareResolutionPlan(deleteIDs: [], keptIDs: [], protectedIDs: [])
        for id in memberIDs {
            if accepted.contains(id) {
                plan.keptIDs.append(id)
            } else if rejected.contains(id) || deleteUnmarked {
                if DeckCardImagePolicy.compareDeleteAllowed(quality: quality[id] ?? .loading) {
                    plan.deleteIDs.append(id)
                } else {
                    plan.protectedIDs.append(id)
                }
            }
        }
        return plan
    }

    /// Shown after a confirm that protected members, nil when none were.
    var notice: String? {
        guard !protectedIDs.isEmpty else { return nil }
        let n = protectedIDs.count
        return "\(n) photo\(n == 1 ? "" : "s") kept — not downloaded yet. Go online to delete \(n == 1 ? "it" : "them")."
    }
}
