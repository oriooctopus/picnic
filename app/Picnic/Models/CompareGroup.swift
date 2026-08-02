import Foundation
import Photos

struct CompareGroup: Identifiable {
    /// Stable key derived from sorted member local identifiers, so the same
    /// physical cluster always resolves to the same id across relaunches.
    let id: String
    let assets: [PHAsset] // chronological within the group
}
