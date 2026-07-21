import AppKit

/// The palette is an overlay in its owning document window.  Keeping the actual
/// controls in that window makes the blur sample the document beneath it and
/// avoids creating an additional AppKit window for a transient command surface.
enum PalettePresentationMode: String, Equatable {
    case inlineMain = "inline-main"
}

enum PalettePresentationPolicy {
    static func mode(
        isVisualTest _: Bool,
        launchesForeground _: Bool,
        hasActivated _: Bool
    ) -> PalettePresentationMode {
        .inlineMain
    }
}
