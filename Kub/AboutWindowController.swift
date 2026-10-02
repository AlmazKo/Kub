import AppKit

/// Custom About window replacing the stock `orderFrontStandardAboutPanel`: the
/// hero artwork (the low-poly Kub bear) fills the whole window, with the app
/// name + slogan overlaid on its dark side and the version line in the corner.
@MainActor
final class AboutWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        self.init(window: window)
        window.contentView = Self.makeContent()
        window.center()
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Content

    private static func makeContent() -> NSView {
        let root = NSView()

        // The artwork bleeds under the (transparent) titlebar to the window's top edge.
        let hero = AboutHeroView()
        hero.image = NSImage(named: "AboutHero")
        hero.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hero)

        let title = NSTextField(labelWithString: "Kub")
        title.font = roundedFont(size: 46, weight: .bold)
        title.textColor = .white

        // "bear", not a typo: Baloo's "Bare Necessities" + the cub (Kub = K8s + cub).
        let slogan = NSTextField(labelWithString: "The bear necessities of Kubernetes.")
        slogan.font = .systemFont(ofSize: 13, weight: .medium)
        slogan.textColor = NSColor.white.withAlphaComponent(0.85)

        let titleStack = NSStackView(views: [title, slogan])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(titleStack)

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        let meta = NSTextField(labelWithString: "Version \(version)\(build) · © 2026 Alex Suslov")
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = NSColor.white.withAlphaComponent(0.7)
        meta.translatesAutoresizingMaskIntoConstraints = false
        hero.addSubview(meta)

        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: root.topAnchor),
            hero.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hero.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hero.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            titleStack.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 32),
            titleStack.centerYAnchor.constraint(equalTo: hero.centerYAnchor, constant: -10),

            meta.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 32),
            meta.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -16),
        ])
        return root
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// Aspect-fills the artwork (the bear is composed off-center in the image
/// itself, so a plain centered fill is enough; `focus`/`anchor`/`zoom` remain
/// as nudge knobs, clamped so the artwork always covers the view). A
/// leading-edge scrim keeps the overlaid white title legible on any crop.
final class AboutHeroView: NSView {
    var image: NSImage?
    /// Unit point of the image pinned near `anchor` (a unit point of the view).
    var focus = NSPoint(x: 0.5, y: 0.5)
    var anchor = NSPoint(x: 0.5, y: 0.5)
    var zoom: CGFloat = 1.0

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            NSColor.black.setFill()
            bounds.fill()
            return
        }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height) * zoom
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        var origin = NSPoint(x: anchor.x * bounds.width - focus.x * drawn.width,
                             y: anchor.y * bounds.height - focus.y * drawn.height)
        origin.x = min(max(origin.x, bounds.width - drawn.width), 0)
        origin.y = min(max(origin.y, bounds.height - drawn.height), 0)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: origin, size: drawn), from: .zero,
                   operation: .sourceOver, fraction: 1)

        let scrim = NSGradient(starting: NSColor.black.withAlphaComponent(0.55), ending: .clear)
        scrim?.draw(in: NSRect(x: 0, y: 0, width: bounds.width * 0.55, height: bounds.height), angle: 0)
    }
}
