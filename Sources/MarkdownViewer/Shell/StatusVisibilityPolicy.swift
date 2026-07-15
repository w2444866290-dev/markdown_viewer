import Foundation

struct StatusVisibilityPolicy: Equatable {
    static let recoveryDelay: TimeInterval = 0.80

    private(set) var isFaded = false
    private(set) var generation = 0

    mutating func registerScrollActivity() -> Int {
        generation += 1
        isFaded = true
        return generation
    }

    @discardableResult
    mutating func recover(ifCurrent candidateGeneration: Int) -> Bool {
        guard candidateGeneration == generation else { return false }
        isFaded = false
        return true
    }

    mutating func reset() {
        generation += 1
        isFaded = false
    }
}

struct ScrollActivityTracker: Equatable {
    static let movementEpsilon: CGFloat = 0.5

    private(set) var lastY: CGFloat?

    mutating func observe(_ y: CGFloat, suppressed: Bool = false) -> Bool {
        let boundedY = max(0, y)
        defer { lastY = boundedY }
        guard !suppressed, let lastY else { return false }
        return abs(lastY - boundedY) > Self.movementEpsilon
    }

    mutating func reset() {
        lastY = nil
    }
}
