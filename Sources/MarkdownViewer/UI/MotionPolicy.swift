import AppKit
import SwiftUI

enum MotionPolicy {
    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func transition(
        _ transition: AnyTransition,
        reduceMotion: Bool
    ) -> AnyTransition {
        reduceMotion ? .identity : transition
    }

    static func delay(_ delay: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : delay
    }

    static func perform(
        reduceMotion: Bool,
        animation: Animation,
        updates: () -> Void
    ) {
        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction, updates)
        } else {
            withAnimation(animation, updates)
        }
    }
}
