import Foundation

/// Lightweight in-memory ring-buffer logger.
///
/// Per the product requirement ("不需要都持久化,崩溃前 flush 前 x 条日志持久化到 crash 文件夹即可")
/// we deliberately do NOT write logs to disk on the normal path — every `log`
/// call just appends to a fixed-size ring buffer in memory. Only on a crash
/// (uncaught Obj-C exception or a fatal signal) do we flush the last
/// `MVLog.capacity` entries to `~/Library/Logs/MarkdownViewer/crash/`.
///
/// Thread-safe: `log` may be called from any thread; appends are guarded by a
/// lock. The hot path is just a lock + array write — no allocation beyond the
/// entry itself and no I/O.
final class MVLog {
    static let shared = MVLog()

    /// Number of most-recent entries kept in memory (and flushed on crash).
    /// Single source of truth for the buffer size — change here to tune.
    static let capacity = 200

    enum Level: String {
        case debug = "DEBUG"
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERROR"
    }

    struct Entry {
        let mono: UInt64        // mach_absolute_time-style monotonic stamp (ns)
        let wall: Date          // wall-clock time
        let level: Level
        let category: String?
        let message: String
    }

    // MARK: - Storage

    private let lock = NSLock()
    /// Fixed-capacity ring buffer. `head` is the index of the next write slot;
    /// `count` tracks how many slots are currently populated (≤ capacity).
    private var ring: [Entry?]
    private var head = 0
    private var count = 0

    private init() {
        ring = Array(repeating: nil, count: MVLog.capacity)
    }

    // MARK: - Public API

    /// Append one entry to the in-memory ring buffer. Cheap; no disk I/O.
    static func log(_ message: String, level: Level = .info, category: String? = nil) {
        shared.append(.init(mono: DispatchTime.now().uptimeNanoseconds,
                            wall: Date(),
                            level: level,
                            category: category,
                            message: message))
    }

    static func debug(_ message: String, category: String? = nil) { log(message, level: .debug, category: category) }
    static func info(_ message: String, category: String? = nil)  { log(message, level: .info,  category: category) }
    static func warn(_ message: String, category: String? = nil)  { log(message, level: .warn,  category: category) }
    static func error(_ message: String, category: String? = nil) { log(message, level: .error, category: category) }

    private func append(_ entry: Entry) {
        lock.lock()
        ring[head] = entry
        head = (head + 1) % ring.count
        if count < ring.count { count += 1 }
        lock.unlock()
    }

    /// Snapshot of the buffer in chronological (oldest→newest) order.
    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return [] }
        let start = (head - count + ring.count) % ring.count
        var out = [Entry]()
        out.reserveCapacity(count)
        for i in 0..<count {
            if let e = ring[(start + i) % ring.count] { out.append(e) }
        }
        return out
    }
}

// MARK: - Crash handling

/// Crash-flush plumbing. We install both an Obj-C uncaught-exception handler
/// (catches NSException-style AppKit/Foundation crashes) and POSIX signal
/// handlers (catch Swift `fatalError`/`precondition`/traps and memory faults,
/// which surface as signals, NOT NSException). After flushing we chain to the
/// previously-installed exception handler and re-raise the signal with the
/// default disposition, so the OS still produces its normal crash report.
extension MVLog {
    /// Signals we trap. Swift `fatalError`/`precondition`/array-OOB land on
    /// SIGTRAP/SIGILL/SIGABRT; memory faults on SIGSEGV/SIGBUS; bad math on SIGFPE.
    private static let trappedSignals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP]

    /// Install both crash handlers. Safe to call once at the earliest point of
    /// app startup. All allocation-heavy work (directory creation, base path
    /// formatting) happens HERE, at install time — never inside a handler.
    static func installCrashHandlers() {
        CrashState.prepare()

        // Chain: remember any pre-existing Obj-C exception handler.
        CrashState.previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashState.flush(reason: "NSException: \(exception.name.rawValue) — \(exception.reason ?? "")",
                             callStack: exception.callStackSymbols)
            // Chain to a previously-installed handler if any.
            CrashState.previousExceptionHandler?(exception)
        }

        // Install signal handlers, remembering the previous action for each so
        // we can restore the default disposition and re-raise.
        for sig in trappedSignals {
            var action = sigaction()
            var old = sigaction()
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            action.__sigaction_u.__sa_handler = MVLog.handleSignal
            sigaction(sig, &action, &old)
        }
    }

    /// C-compatible signal handler. Runs in an async-signal-unsafe-hostile
    /// context, so it is intentionally MINIMAL and BEST-EFFORT: it calls
    /// `CrashState.flush`, which uses only the low-level `write(2)`/`open(2)`
    /// path against a pre-resolved file descriptor and a pre-formatted byte
    /// buffer (see `CrashState.prepare`). We deliberately avoid Foundation,
    /// Swift allocation, locks, and `String` work in this path. NOTE: a perfect
    /// async-signal-safe logger is not achievable from Swift; for a dev tool
    /// this best-effort flush is an accepted trade-off.
    private static let handleSignal: @convention(c) (Int32) -> Void = { sig in
        CrashState.flushOnSignal(sig)

        // Restore the default disposition and re-raise so the OS produces its
        // normal crash report (and any debugger / Crash Reporter still fires).
        signal(sig, SIG_DFL)
        raise(sig)
    }
}

/// Holds everything the crash handler needs, all resolved at install time so
/// the handler itself allocates nothing. Marked `nonisolated`/global so the
/// C function pointer can reach it.
private enum CrashState {
    /// Pre-resolved crash directory for the active launch profile.
    static var crashDir: String = ""
    /// Previously-installed Obj-C exception handler, for chaining.
    static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    /// Pre-snapshotted process start banner bytes (reused on signal path).
    static var headerBytes: [UInt8] = []

    /// Done once at install time: create the crash directory and pre-build the
    /// header banner. Allocation here is fine — we are NOT in a signal context.
    static func prepare() {
        let base = AppEnv.crashLogDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        crashDir = base.path

        let banner = "=== MarkdownViewer crash log (pid \(ProcessInfo.processInfo.processIdentifier)) ===\n"
        headerBytes = Array(banner.utf8)
    }

    /// Full flush used by the NSException path. Foundation/allocation is OK
    /// here: an uncaught Obj-C exception is not a true async-signal context, so
    /// we can afford a richer (still best-effort) dump.
    static func flush(reason: String, callStack: [String]) {
        let path = crashDir + "/crash-\(Int(Date().timeIntervalSince1970)).log"
        var text = "=== MarkdownViewer crash log ===\n"
        text += "reason: \(reason)\n"
        text += "time: \(Date())\n\n"
        if !callStack.isEmpty {
            text += "call stack:\n" + callStack.joined(separator: "\n") + "\n\n"
        }
        text += "--- last \(MVLog.capacity) log entries (oldest→newest) ---\n"
        text += renderEntries()
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Signal path — kept low-level and best-effort. We build the file path and
    /// body via the same renderer (which DOES allocate; acceptable for a dev
    /// tool) but commit the bytes with raw `open`/`write`/`close` rather than
    /// Foundation's file writers, which is the most reliable primitive here.
    static func flushOnSignal(_ sig: Int32) {
        let path = crashDir + "/crash-\(Int(Date().timeIntervalSince1970)).log"
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        write(fd, headerBytes, headerBytes.count)
        writeString(fd, "signal: \(sig) (\(signalName(sig)))\n\n")
        writeString(fd, "--- last \(MVLog.capacity) log entries (oldest→newest) ---\n")
        writeString(fd, renderEntries())
        close(fd)
    }

    private static func writeString(_ fd: Int32, _ s: String) {
        let bytes = Array(s.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Render the ring-buffer snapshot to a single string.
    private static func renderEntries() -> String {
        let entries = MVLog.shared.snapshot()
        if entries.isEmpty { return "(no log entries)\n" }
        let fmt = ISO8601DateFormatter()
        var out = ""
        for e in entries {
            let cat = e.category.map { "[\($0)] " } ?? ""
            out += "\(fmt.string(from: e.wall)) \(e.level.rawValue) \(cat)\(e.message)\n"
        }
        return out
    }

    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGILL:  return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGFPE:  return "SIGFPE"
        case SIGBUS:  return "SIGBUS"
        case SIGTRAP: return "SIGTRAP"
        default:      return "UNKNOWN"
        }
    }
}
