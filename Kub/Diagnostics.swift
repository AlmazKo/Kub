import Foundation

/// async-profiler presets, mirroring profile-async.bash. Output format is JFR.
enum AsyncProfile: String, CaseIterable, Sendable {
    case cpu, alloc, wall, lock, native

    var menuTitle: String {
        switch self {
        case .cpu: return "CPU"
        case .alloc: return "Allocations"
        case .wall: return "Wall Clock"
        case .lock: return "Locks"
        case .native: return "Native Memory"
        }
    }

    /// asprof argument string for the given pid/duration/output (one preset each).
    func asprofArgs(pid: String, seconds: Int, outPath: String) -> String {
        switch self {
        case .cpu:    return "-e cpu -i 1ms -t -d \(seconds) -f \(outPath) \(pid)"
        case .wall:   return "-e wall -i 1ms -t -d \(seconds) -f \(outPath) \(pid)"
        case .alloc:  return "-e alloc --alloc 64k -t -d \(seconds) -f \(outPath) \(pid)"
        case .lock:   return "-e lock -t -d \(seconds) -f \(outPath) \(pid)"
        case .native: return "-e nativemem -i 1ms -t -d \(seconds) -f \(outPath) \(pid)"
        }
    }
}

/// A diagnostic requested from the process-table context menu. Pod identity is
/// captured here (at menu-build time) so a later selection change can't retarget it.
struct ProcessAction: Sendable {
    enum Kind: Sendable {
        case heapDump
        case profile(AsyncProfile)
    }
    let kind: Kind
    let pid: String
    let command: String
    let namespace: String
    let podName: String
}

/// Local file locations and the async-profiler asset. Tweak here to relocate.
enum DiagnosticPaths {
    /// Heap dumps → <Settings.heapDumpsDirectory>/<namespace>/.
    static func dumpsDir(_ namespace: String) -> String { Settings.heapDumpsDirectory + "/\(namespace)" }
    /// Profiles → /tmp/kub/profiles/<namespace>/.
    static func profilesDir(_ namespace: String) -> String { "/tmp/kub/profiles/\(namespace)" }

    /// async-profiler (linux-x64) ships *inside the app bundle* (Contents/Resources/,
    /// copied there by build.sh) and is uploaded into the pod per run. The dir name
    /// must match the tar's top-level folder.
    static let asyncProfilerVersion = "4.4"
    static var asyncProfilerDir: String { "async-profiler-\(asyncProfilerVersion)-linux-x64" }
    static var asyncProfilerTar: URL? {
        Bundle.main.url(forResource: asyncProfilerDir, withExtension: "tar")
    }
}

/// Minimal async wrapper to run a local binary (e.g. gunzip) off the main thread.
enum LocalProcess {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = args
                let outPipe = Pipe(), errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do { try process.run() } catch { cont.resume(throwing: error); return }
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                let err = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    cont.resume(returning: String(decoding: out, as: UTF8.self))
                } else {
                    let msg = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: KubectlError(
                        message: msg.isEmpty ? "\(launchPath) exited \(process.terminationStatus)" : msg,
                        code: process.terminationStatus))
                }
            }
        }
    }
}
