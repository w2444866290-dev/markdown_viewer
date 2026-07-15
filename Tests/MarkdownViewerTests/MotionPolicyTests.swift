import SwiftUI
import Testing
@testable import MarkdownViewer

@Suite
struct MotionPolicyTests {
    @Test
    func reducedMotionSuppressesAnimationAndDelay() {
        let animation = MotionPolicy.animation(
            .easeOut(duration: 0.18),
            reduceMotion: true
        )

        #expect(animation == nil)
        #expect(MotionPolicy.delay(0.18, reduceMotion: true) == 0)
    }

    @Test
    func standardMotionPreservesAnimationAndDelay() {
        let animation = MotionPolicy.animation(
            .easeOut(duration: 0.18),
            reduceMotion: false
        )

        #expect(animation != nil)
        #expect(MotionPolicy.delay(0.18, reduceMotion: false) == 0.18)
    }
}
