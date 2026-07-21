import Foundation

enum OutlineBehaviorPolicy {
    static let currentHeadingThreshold: CGFloat = 140
    static let hoverLeaveDelay: TimeInterval = 0.18
    static let railExpansionDuration: TimeInterval = 0.18
    static let railRowHeightDuration: TimeInterval = 0.24
    static let railRowStagger: TimeInterval = 0.012
    // The prototype's 130pt content minimum plus its 30pt top and bottom
    // padding produces a 190pt interactive rail, even for a one-heading file.
    static let railMinimumHitHeight: CGFloat = 190
    static let currentTickColorDuration: TimeInterval = 0.20
    static let currentLabelColorDuration: TimeInterval = 0.15
    static let rowHoverDuration: TimeInterval = 0.12
    static let jumpDuration: TimeInterval = 0.30
    static let jumpTopInset: CGFloat = 40
    static let washDuration: TimeInterval = 0.90
    static let washOpacity = 0.30

    static func railExpansionSettlingDelay(rowIndex: Int) -> TimeInterval {
        max(railExpansionDuration, railRowHeightDuration)
            + Double(max(0, rowIndex)) * railRowStagger
    }

    /// Resolves the current heading from stable document-space geometry.
    /// The first heading remains current until a later heading crosses the threshold.
    static func activeHeadingIndex(
        headingDocumentMinYs: [CGFloat],
        viewportTop: CGFloat
    ) -> Int? {
        guard !headingDocumentMinYs.isEmpty else { return nil }
        let threshold = max(0, viewportTop) + currentHeadingThreshold
        var lowerBound = 0
        var upperBound = headingDocumentMinYs.count - 1
        var activeIndex = 0
        while lowerBound <= upperBound {
            let candidate = (lowerBound + upperBound) / 2
            if headingDocumentMinYs[candidate] <= threshold {
                activeIndex = candidate
                lowerBound = candidate + 1
            } else {
                upperBound = candidate - 1
            }
        }
        return activeIndex
    }

    /// Resolves the current heading from viewport-space frames emitted by SwiftUI.
    /// Missing frames are expected with LazyVStack. A measured heading below the
    /// threshold proves that its immediate predecessor is current, even when that
    /// predecessor is outside the realized view range.
    static func activeHeadingIndex<ID: Hashable>(
        orderedHeadingIDs: [ID],
        viewportMinYByHeadingID: [ID: CGFloat],
        previousIndex: Int
    ) -> Int? {
        guard !orderedHeadingIDs.isEmpty else { return nil }
        let boundedPrevious = min(max(0, previousIndex), orderedHeadingIDs.count - 1)
        var lastCrossedIndex: Int?

        for (index, id) in orderedHeadingIDs.enumerated() {
            guard let minY = viewportMinYByHeadingID[id] else { continue }
            if minY > currentHeadingThreshold {
                return max(0, index - 1)
            }
            lastCrossedIndex = index
        }

        guard let lastCrossedIndex else { return boundedPrevious }
        return max(boundedPrevious, lastCrossedIndex)
    }
}

struct OutlineRailInteractionState: Equatable {
    private(set) var expanded = false
    private(set) var hoveredIndex: Int?
    private(set) var generation = 0

    mutating func enterRail() {
        generation += 1
        expanded = true
    }

    mutating func leaveRail() -> Int {
        generation += 1
        return generation
    }

    mutating func setHoveredIndex(_ index: Int?) {
        hoveredIndex = index
    }

    @discardableResult
    mutating func collapse(ifCurrent candidateGeneration: Int) -> Bool {
        guard candidateGeneration == generation else { return false }
        expanded = false
        hoveredIndex = nil
        return true
    }

    mutating func reset() {
        generation += 1
        expanded = false
        hoveredIndex = nil
    }
}

struct OutlineWashState<ID: Equatable>: Equatable {
    private(set) var generation = 0
    private(set) var blockID: ID?

    mutating func beginNavigation() -> Int {
        generation += 1
        blockID = nil
        return generation
    }

    @discardableResult
    mutating func beginWash(_ id: ID, ifCurrent candidateGeneration: Int) -> Bool {
        guard candidateGeneration == generation else { return false }
        blockID = id
        return true
    }

    func isCurrent(_ candidateGeneration: Int) -> Bool {
        candidateGeneration == generation
    }

    @discardableResult
    mutating func finishWash(ifCurrent candidateGeneration: Int) -> Bool {
        guard candidateGeneration == generation else { return false }
        blockID = nil
        return true
    }

    mutating func reset() {
        generation += 1
        blockID = nil
    }
}
