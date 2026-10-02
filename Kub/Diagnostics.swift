import Foundation

/// async-profiler presets (one asprof event config each). Output format is JFR.
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
        // Wall mode samples EVERY thread each interval; 1ms on a few hundred threads is
        // a measurable load on the target — 10ms is the upstream-recommended default.
        case .wall:   return "-e wall -i 10ms -t -d \(seconds) -f \(outPath) \(pid)"
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

    /// async-profiler ships *inside the app bundle* (Contents/Resources/, one tar per
    /// Linux architecture — x64 and arm64/Graviton) and is uploaded into the pod per
    /// run. The dir name must match the tar's top-level folder.
    static let asyncProfilerVersion = "4.4"

    /// Bundle flavour for a node's `nodeInfo.architecture`; nil = no build for it.
    /// Unknown (nil) arch assumes amd64, by far the most common.
    static func asyncProfilerFlavor(arch: String?) -> String? {
        switch arch ?? "amd64" {
        case "amd64", "x86_64": return "linux-x64"
        case "arm64", "aarch64": return "linux-arm64"
        default: return nil
        }
    }
    static func asyncProfilerDir(arch: String?) -> String? {
        asyncProfilerFlavor(arch: arch).map { "async-profiler-\(asyncProfilerVersion)-\($0)" }
    }
    static func asyncProfilerTar(arch: String?) -> URL? {
        asyncProfilerDir(arch: arch).flatMap { Bundle.main.url(forResource: $0, withExtension: "tar") }
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
