import AppKit
import SwiftTerm

/// An interactive `kubectl exec -it` shell hosted in a SwiftTerm terminal. A
/// connect overlay (prod-flagged) gates it so we never auto-exec into a pod on
/// tab open; the child process is killed on `stop()` (section/row change, close).
final class PodShellView: NSView, LocalProcessTerminalViewDelegate {
    private let terminal = LocalProcessTerminalView(frame: .zero)
    private let overlay = NSView()
    private let overlayTitle = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton()

    private var context = "", namespace = "", pod = ""
    private var container: String?          // nil → kubectl's default container
    private var isProduction = false
    private(set) var running = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.processDelegate = self
        addSubview(terminal)
        applyTheme()

        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        overlay.layer?.cornerRadius = 10
        overlay.layer?.borderWidth = 1
        overlay.layer?.borderColor = NSColor.separatorColor.cgColor
        overlayTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        overlayTitle.alignment = .center
        overlayTitle.lineBreakMode = .byTruncatingMiddle
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemRed
        warningLabel.alignment = .center
        warningLabel.maximumNumberOfLines = 0
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectTapped)

        let stack = NSStackView(views: [overlayTitle, warningLabel, connectButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        addSubview(overlay)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            // A centered card (not a full cover) so the terminal's output — e.g. an
            // error before the session ended — stays visible around it.
            overlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -20),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// SwiftTerm defaults to a muted, fixed-dark scheme. Use the system text/
    /// background colours (which follow light↔dark) for the default fg/bg, plus a
    /// vivid ANSI palette on dark and a darkened one on light so colours aren't
    /// washed out (dark) or invisible on white (light).
    private func applyTheme() {
        terminal.configureNativeColors()            // fg/bg = textColor / textBackgroundColor
        terminal.caretColor = .textColor
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        terminal.installColors(dark ? Self.darkPalette : Self.lightPalette)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()                                // re-resolve the colours for the new theme
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
    }
    /// Vivid xterm-style palette for a dark background.
    private static let darkPalette: [SwiftTerm.Color] = [
        rgb(40, 40, 40),    rgb(224, 70, 70),   rgb(40, 200, 120),  rgb(224, 192, 60),
        rgb(74, 144, 232),  rgb(206, 100, 206), rgb(48, 190, 214),  rgb(214, 214, 214),
        rgb(130, 130, 130), rgb(240, 100, 100), rgb(70, 220, 150),  rgb(238, 214, 100),
        rgb(104, 168, 245), rgb(222, 130, 222), rgb(90, 208, 228),  rgb(245, 245, 245),
    ]
    /// Darkened palette so the same colours stay legible on a light (white) background.
    private static let lightPalette: [SwiftTerm.Color] = [
        rgb(0, 0, 0),       rgb(184, 32, 32),   rgb(20, 132, 74),   rgb(150, 112, 12),
        rgb(28, 92, 176),   rgb(150, 46, 150),  rgb(20, 120, 142),  rgb(92, 92, 92),
        rgb(72, 72, 72),    rgb(200, 48, 48),   rgb(26, 150, 88),   rgb(168, 128, 18),
        rgb(40, 108, 200),  rgb(168, 70, 168),  rgb(28, 138, 160),  rgb(30, 30, 30),
    ]

    /// Point the view at a pod. Idempotent for the same pod (keeps a live session);
    /// switching pods drops the old one and shows the connect overlay. `container`
    /// is the app container (see `PodContainers.main`); nil leaves it to kubectl.
    func configure(context: String, namespace: String, pod: String, container: String?, isProduction: Bool) {
        if running, (context, namespace, pod) != (self.context, self.namespace, self.pod) { stop() }
        self.context = context; self.namespace = namespace; self.pod = pod; self.isProduction = isProduction
        if !running { self.container = container }   // a live session keeps the container it opened with
        if !running { showOverlay(title: container.map { "Shell into “\(pod)” (\($0))" } ?? "Shell into “\(pod)”") }
    }

    @objc private func connectTapped() { start() }

    private func start() {
        guard !running, !pod.isEmpty else { return }
        // env + augmented PATH so `kubectl` (and its EKS `aws` exec-auth) resolve.
        var env = Kubectl.augmentedEnvironment()
        env["TERM"] = "xterm-256color"
        // Absolute kubectl path — a bare `env kubectl` exits 127 when the PTY child's
        // PATH isn't right; kubectl still gets the augmented PATH for its aws exec-auth.
        let kube = Kubectl.resolvedExecutable()
        // Pick the best available shell WITHOUT `exec bash || exec sh`: a failed
        // `exec` terminates the shell (127) before the fallback runs, so probe with
        // `command -v` first. Prefers bash, then ash (Alpine), then plain sh.
        let pickShell = "for s in bash ash sh; do command -v \"$s\" >/dev/null 2>&1 && exec \"$s\"; done"
        let args = kube.prefix + ["--context", context, "-n", namespace, "exec", "-it", pod]
            + (container.map { ["-c", $0] } ?? []) + ["--", "sh", "-c", pickShell]
        terminal.startProcess(executable: kube.path, args: args,
                              environment: env.map { "\($0.key)=\($0.value)" })
        running = true
        overlay.isHidden = true
        window?.makeFirstResponder(terminal)
    }

    /// Kill the child kubectl/exec process (idempotent).
    func stop() {
        guard running else { return }
        terminal.terminate()
        running = false
    }

    /// `ended` = a session just finished, so the button offers to reconnect.
    private func showOverlay(title: String, ended: Bool = false) {
        overlayTitle.stringValue = title
        warningLabel.isHidden = !isProduction
        warningLabel.stringValue = isProduction
            ? "⚠︎ Production context — this opens an interactive shell into a live pod."
            : ""
        connectButton.title = ended ? "Reconnect" : "Start Shell"
        overlay.isHidden = false
    }

    // MARK: - LocalProcessTerminalViewDelegate (nonisolated — SwiftTerm's protocol
    // isn't @MainActor; hop back to the main actor for UI).

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.running = false
            self.showOverlay(title: exitCode.map { "Session ended (exit \($0)) — “\(self.pod)”" }
                                    ?? "Session ended — “\(self.pod)”", ended: true)
        }
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
