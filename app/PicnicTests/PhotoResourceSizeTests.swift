import XCTest
import Photos
import UIKit
@testable import Picnic

/// BestPhotoResolver reads PHAssetResource's non-public `fileSize` by KVC.
/// This runs against a real asset in the simulator's library, so a renamed or
/// wrong key (which would silently make every size 0, or throw) fails here.
final class PhotoResourceSizeTests: XCTestCase {
    func testFileSizeOfARealAssetMatchesItsBytes() async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            XCTFail("photo access is not granted (\(status.rawValue)); CI grants it with simctl privacy, so this test cannot run without it")
            return
        }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48))
        let jpeg = renderer.jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        var localID = ""
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: jpeg, options: nil)
            request.creationDate = Date(timeIntervalSince1970: 1_546_300_800)  // 2019-01-01
            localID = request.placeholderForCreatedAsset?.localIdentifier ?? ""
        }
        XCTAssertFalse(localID.isEmpty)
        let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject)

        XCTAssertEqual(
            BestPhotoResolver.fileSize(for: asset), Int64(jpeg.count),
            "BestPhotoResolver.fileSize must read the real resource size (wrong KVC key or missing fallback gives 0 / throws)"
        )
    }
}
