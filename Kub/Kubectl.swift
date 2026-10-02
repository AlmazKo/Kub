import Foundation

struct KubectlError: Error, LocalizedError {
    let message: String
    let code: Int32
    var errorDescription: String? { message }
}

/// Mutable `Data` holder so stderr can be drained on a second queue without
/// tripping Swift 6's "mutation of captured var in concurrently-executing code".
/// The DispatchGroup barrier provides the happens-before, hence `@unchecked` —
/// readers must only touch `data` after a successful group wait.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// SIGTERM now, SIGKILL 5s later if it's still alive. kubectl normally dies on
/// SIGTERM, but its handler can wedge inside an exec-auth plugin call (`aws
/// eks get-token` offline), and a watchdog that only SIGTERMs would never
/// actually free anything then.
private func terminateWithEscalation(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let killer = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
}

/// Hands a spawned process to task cancellation: `cancel()` terminates it from
/// whatever thread the cancellation handler runs on. `@unchecked Sendable`: the
/// lock guards both fields.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Publish the (already running) process. Returns false when `cancel()` won
    /// the race — the caller must kill the process itself.
    func register(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        process = p
        return true
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p { terminateWithEscalation(p) }
    }
}

/// Caps how many kubectl processes run at once. Waiting is an async suspension
/// (no blocked thread); only the running ones occupy a (pooled) thread.
private actor ConcurrencyGate {
    private let limit: Int
    private var active = 0
    private var highWaiters: [CheckedContinuation<Void, Never>] = []
    private var lowWaiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    /// High-priority acquirers (user-visible work: the visible table, detail-pane
    /// reads, confirmed mutations) are handed freed slots before low-priority
    /// background work (sidebar counts, arch cache, unread badges), so a 60s burst
    /// of ~22 count queries can't delay what the user is actually waiting on.
    func acquire(highPriority: Bool) async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if highPriority { highWaiters.append(c) } else { lowWaiters.append(c) }
        }
    }

    func release() {
        if !highWaiters.isEmpty {
            highWaiters.removeFirst().resume()      // hand the slot to a high-priority waiter first
        } else if !lowWaiters.isEmpty {
            lowWaiters.removeFirst().resume()
        } else {
            active -= 1
        }
    }
}

/// A long-lived, streaming kubectl process (`logs -f`, `port-forward`). Delivers
/// stdout line-by-line and can be stopped. Runs OUTSIDE the concurrency gate — a
/// stream would otherwise hold a slot for its whole lifetime and starve polling.
/// `@unchecked Sendable`: the NSLock guards `stopped`, and the reader thread only
/// touches the process/pipes it owns.
final class KubectlProcess: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let lock = NSLock()
    private var stopped = false

    fileprivate init(executableURL: URL, arguments: [String], environment: [String: String]) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    /// Kill the process (idempotent). The reader thread then hits EOF and calls onEnd(nil).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        terminateWithEscalation(process)
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    fileprivate func start(onLine: @escaping @Sendable (String) -> Void,
                           onEnd: @escaping @Sendable (KubectlError?) -> Void) {
        do { try process.run() }
        catch { onEnd(KubectlError(message: error.localizedDescription, code: -1)); return }

        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let outHandle = outPipe.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = outHandle.availableData   // blocks until data or EOF (empty)
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {   // emit complete lines
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    onLine(String(decoding: line, as: UTF8.self))
                }
            }
            if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }
            process.waitUntilExit()
            // Bound the stderr drain: an exec-auth child (`aws`) inherits the pipe's
            // write end and can outlive kubectl, and an unbounded wait would delay
            // onEnd (and session cleanup) until IT exits. On a lost race skip errBox
            // entirely — the reader thread may still be writing it.
            let drained = group.wait(timeout: .now() + 5) == .success
            if isStopped || process.terminationStatus == 0 {
                onEnd(nil)
            } else {
                let err = drained
                    ? String(decoding: errBox.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                onEnd(KubectlError(message: err.isEmpty ? "stream ended (code \(process.terminationStatus))" : err,
                                   code: process.terminationStatus))
            }
        }
    }
}

/// Bridges a streaming `port-forward`'s stdout to an async "tunnel ready on local
/// port N" await. Resolves exactly once — on the "Forwarding from 127.0.0.1:<port>"
/// line, on stream end, on timeout, or on task cancellation. `@unchecked Sendable`:
/// all state is guarded by the lock.
final class PortForwardReady: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var pending: Result<Int, Error>?
    private var cont: CheckedContinuation<Int, Error>?

    /// stdout line from the port-forward (ignored unless it announces the port).
    func consume(_ line: String) {
        guard let port = Self.parseLocalPort(line) else { return }
        resolve(.success(port))
    }

    /// The stream ended (before or after we got the port — no-op if already resolved).
    func finish(_ error: KubectlError?) {
        resolve(.failure(error ?? KubectlError(message: "port-forward ended before ready", code: -1)))
    }

    /// Await the local port. Throws on stream failure, `timeout`, or cancellation.
    func waitForPort(timeout: TimeInterval) async throws -> Int {
        let timer = DispatchWorkItem { [weak self] in
            self?.resolve(.failure(KubectlError(message: "port-forward not ready (timed out)", code: -1)))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int, Error>) in
                lock.lock()
                if let pending {
                    lock.unlock()
                    c.resume(with: pending)
                } else {
                    cont = c
                    lock.unlock()
                }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    private func resolve(_ result: Result<Int, Error>) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        if let c = cont {
            cont = nil
            lock.unlock()
            c.resume(with: result)
        } else {
            pending = result
            lock.unlock()
        }
    }

    /// "Forwarding from 127.0.0.1:<port> -> <remote>" → <port> (skips the IPv6 line).
    static func parseLocalPort(_ line: String) -> Int? {
        guard line.contains("Forwarding from"), let r = line.range(of: "127.0.0.1:") else { return nil }
        return Int(line[r.upperBound...].prefix { $0.isNumber })
    }
}

/// Thin async wrapper around the `kubectl` binary.
///
/// Each call runs on a shared GCD pool (threads are reused, not one-per-call) and
/// is bounded by `gate`, so a burst of requests can't spawn a thread per request.
final class Kubectl: Sendable {
    private let executableURL: URL
    private let prefixArgs: [String]
    private let gate: ConcurrencyGate

    init(gateLimit: Int = 6) {
        gate = ConcurrencyGate(limit: gateLimit)
        let (path, prefix) = Self.resolvedExecutable()
        executableURL = URL(fileURLWithPath: path)
        prefixArgs = prefix
    }

    /// Resolved kubectl invocation — for `run`/`stream` and for callers that spawn it
    /// themselves (the shell PTY): an absolute path when found (so no PATH lookup is needed — a bare
    /// `env kubectl` fails when the child PATH isn't right), else the env fallback.
    static func resolvedExecutable() -> (path: String, prefix: [String]) {
        let candidates = ["/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return (found, [])
        }
        return ("/usr/bin/env", ["kubectl"])
    }

    /// `timeout` hard-bounds the process (a watchdog SIGTERMs, then SIGKILLs it),
    /// so a stalled call can't hold its gate slot forever. Reads default to 30s;
    /// long diagnostics pass their own (minutes). This is the backstop for what
    /// `--request-timeout` doesn't cover: the exec-auth plugin (`aws eks get-token`,
    /// hangs offline) and whole `exec`/`cp` sessions (verified: it doesn't bound them). Task cancellation terminates the spawned kubectl and
    /// throws `CancellationError` (any in-cluster effect may still land).
    func run(_ args: [String], timeout: TimeInterval = 30, highPriority: Bool = false) async throws -> Data {
        try Task.checkCancellation()   // abandoned work shouldn't wait for (or take) a slot
        await gate.acquire(highPriority: highPriority)
        do {
            try Task.checkCancellation()
            let data = try await execute(args, timeout: timeout)
            await gate.release()
            return data
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Start a long-lived streaming process (not gated). Returns a stoppable handle.
    func stream(_ args: [String],
                onLine: @escaping @Sendable (String) -> Void,
                onEnd: @escaping @Sendable (KubectlError?) -> Void) -> KubectlProcess {
        let handle = KubectlProcess(executableURL: executableURL,
                                    arguments: prefixArgs + args,
                                    environment: Self.augmentedEnvironment())
        handle.start(onLine: onLine, onEnd: onEnd)
        return handle
    }

    /// GUI launches get launchd's minimal PATH, without /opt/homebrew/bin etc. — where
    /// the `aws` exec-credential plugin lives. Augment it with the usual locations plus
    /// whatever the user's login shell puts on PATH, so kubectl can find the plugins.
    static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var paths = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        if let login = loginShellPath { paths += login.split(separator: ":").map(String.init) }
        paths += ["\(home)/.rd/bin", "\(home)/.krew/bin", "/opt/local/bin",
                  "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let existing = env["PATH"], !existing.isEmpty { paths += existing.split(separator: ":").map(String.init) }
        var seen = Set<String>()
        env["PATH"] = paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// PATH as the user's login shell sees it, probed once (`$SHELL -lc`, 3s cap).
    /// Exec-auth plugins live wherever dotfiles put them — asdf/mise shims,
    /// `google-cloud-sdk/bin` (`gke-gcloud-auth-plugin`), `~/.rd/bin` — and no fixed
    /// list covers that. nil when the shell is missing, prints nothing or hangs.
    private static let loginShellPath: String? = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let marker = "__KUB_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf '\(marker)%s' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let box = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + 3) != .success {   // a prompting dotfile would hang us
            terminateWithEscalation(process)
            return nil
        }
        process.waitUntilExit()
        let out = String(decoding: box.data, as: UTF8.self)
        guard let r = out.range(of: marker) else { return nil }
        let path = out[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }()

    private func execute(_ args: [String], timeout: TimeInterval) async throws -> Data {
        let exe = executableURL
        let allArgs = prefixArgs + args
        let box = ProcessBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if box.isCancelled {   // cancelled while queued — don't even spawn
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    let process = Process()
                    process.executableURL = exe
                    process.arguments = allArgs

                    process.environment = Self.augmentedEnvironment()

                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe

                    do {
                        try process.run()
                    } catch {
                        cont.resume(throwing: error)
                        return
                    }
                    // Publish for cancellation; if cancel() won the race, kill it ourselves
                    // and let the drain fall through to the CancellationError resume below.
                    if !box.register(process) { terminateWithEscalation(process) }

                    // Watchdog: SIGTERM (then SIGKILL) the process if it overruns `timeout`.
                    // `--request-timeout` bounds the API request but NOT the exec-auth plugin
                    // (`aws eks get-token`, hangs when the network drops) nor an exec/cp
                    // session — and a hung process would hold this gate slot indefinitely,
                    // stalling the whole app once all slots are taken.
                    let watchdog = DispatchWorkItem { terminateWithEscalation(process) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                    // Drain stdout and stderr concurrently. Reading one pipe fully
                    // before the other lets a child that fills the second pipe's
                    // buffer (~64KB) block on write: it never exits, the first read
                    // never hits EOF, and this thread — plus its gate slot — hangs
                    // forever, eventually starving all kubectl access.
                    let errHandle = errPipe.fileHandleForReading
                    let errBox = DataBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errBox.data = errHandle.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    // Bound the stderr drain: a killed kubectl's exec-auth child (`aws`)
                    // inherits the pipe's write end and can outlive it, and an unbounded
                    // wait here would keep holding this gate slot past the watchdog. On
                    // a lost race skip errBox — the reader thread may still be writing it.
                    let drained = group.wait(timeout: .now() + 5) == .success
                    watchdog.cancel()
                    let errData = drained ? errBox.data : Data()

                    if box.isCancelled {
                        cont.resume(throwing: CancellationError())
                    } else if process.terminationStatus == 0 {
                        cont.resume(returning: outData)
                    } else if process.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: KubectlError(
                            message: "timed out after \(Int(timeout))s — cluster unreachable? (check network / VPN)",
                            code: process.terminationStatus))
                    } else {
                        let msg = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        cont.resume(throwing: KubectlError(
                            message: msg.isEmpty ? "kubectl exited with code \(process.terminationStatus)" : msg,
                            code: process.terminationStatus))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
