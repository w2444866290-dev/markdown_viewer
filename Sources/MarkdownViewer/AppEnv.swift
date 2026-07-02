import Foundation

// MARK: - Launch environment
//
// A normal launch (double-click, `open MarkdownViewer.app`) runs in plain USER
// mode: no developer instrumentation is shown. Debug mode is opt-in and only
// meant for developers - it turns on the on-screen DIAG HUD (see the
// `// DIAG (temporary)` markers) and its per-keystroke recording.
//
// Enable it either by passing `--debug` on the command line (scripts/run-debug.sh
// does this) or by setting `MV_DEBUG=1` in the environment. Evaluated ONCE at
// startup so the flag is a cheap constant everywhere it is read.
enum AppEnv {
    /// True when this process was launched in developer/debug mode.
    static let debug =
        ProcessInfo.processInfo.arguments.contains("--debug")
        || ProcessInfo.processInfo.environment["MV_DEBUG"] == "1"
}
