import AppKit

/// Minimal Settings window (⌘,). One section for now: the JDK integration.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let dumpsPath = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.contentView = buildContent()
        window.center()
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() -> NSView {
        let header = NSTextField(labelWithString: "JDK Integration")
        header.font = .systemFont(ofSize: 13, weight: .semibold)

        let toggle = NSButton(checkboxWithTitle: "Enable JDK integration",
                              target: self, action: #selector(toggleJDK(_:)))
        toggle.state = Settings.jdkIntegrationEnabled ? .on : .off

        let desc = NSTextField(wrappingLabelWithString:
            "Adds a JDK submenu when you right-click a process in a pod’s Top tab: "
          + "capture a JVM heap dump (jcmd GC.heap_dump) or an async-profiler recording "
          + "(JFR). Requires a Linux JVM pod (x64 or arm64); async-profiler "
          + "\(DiagnosticPaths.asyncProfilerVersion) is bundled in the app. Profiles are "
          + "written to /tmp/kub/profiles.")
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        desc.preferredMaxLayoutWidth = 400

        let dumpsLabel = NSTextField(labelWithString: "Save heap dumps to:")
        dumpsPath.lineBreakMode = .byTruncatingMiddle
        dumpsPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dumpsPath.toolTip = Settings.heapDumpsDirectory
        dumpsPath.stringValue = Self.abbreviated(Settings.heapDumpsDirectory)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseDumpsFolder(_:)))
        choose.controlSize = .small
        let dumpsRow = NSStackView(views: [dumpsLabel, dumpsPath, choose])
        dumpsRow.spacing = 6

        let stack = NSStackView(views: [header, toggle, desc, dumpsRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -22),
        ])
        return container
    }

    @objc private func toggleJDK(_ sender: NSButton) {
        Settings.jdkIntegrationEnabled = sender.state == .on
    }

    /// Picking the folder in an open panel is the user's consent, so even a
    /// TCC-protected location (Desktop / Documents / Downloads) needs no prompt.
    @objc private func chooseDumpsFolder(_ sender: NSButton) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Kub saves heap dumps"
        panel.directoryURL = URL(fileURLWithPath: Settings.heapDumpsDirectory).deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Settings.heapDumpsDirectory = url.path
            self?.dumpsPath.stringValue = Self.abbreviated(url.path)
            self?.dumpsPath.toolTip = url.path
        }
    }

    private static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
