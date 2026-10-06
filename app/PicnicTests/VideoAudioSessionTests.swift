import XCTest
import AVFoundation
@testable import Picnic

/// Silent-video regression: videos played with no sound while the phone's
/// ring/silent switch was on, because the app never left iOS's default
/// (silenced-by-switch) audio session category.
@MainActor
final class VideoAudioSessionTests: XCTestCase {

    func testControllerSetsPlaybackCategorySoSilentSwitchDoesNotMute() throws {
        // Reset to the default category so the test proves the controller sets it.
        try AVAudioSession.sharedInstance().setCategory(.soloAmbient)
        _ = VideoPlaybackController()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    }
}
