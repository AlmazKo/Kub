import AppKit

/// A centered status message (loading / empty / error) shown over a table. An
/// opaque rounded backing with a hairline border keeps it legible over the
/// alternating-row stripes underneath — plain text there is hard to read.
/// Optionally shows an action button (e.g. Reload) below the text.
///
/// Drop-in for the old centered `NSTextField`: exposes `stringValue` / `textColor`
/// and inherits `isHidden`. Layer-backed via `updateLayer`, so it re-themes on a
/// light/dark switch automatically.
final class TableMessageLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton()
    private let stack = NSStackView()

    private var buttonAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor   // readable on the backing — no need to mute it
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.usesSingleLineMode = false

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(actionTapped)
        button.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(button)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    var stringValue: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    var textColor: NSColor? {
        get { label.textColor }
        set { label.textColor = newValue }
    }

    /// Show (non-nil title) an action button below the message with its own
    /// handler, or hide it (nil title).
    func setActionButton(_ title: String?, action: (() -> Void)? = nil) {
        if let title { button.title = title; button.isHidden = false; buttonAction = action }
        else { button.isHidden = true; buttonAction = nil }
    }

    @objc private func actionTapped() { buttonAction?() }

    // Layer-backed drawing: AppKit calls updateLayer within the current appearance,
    // so the backing/border follow light↔dark without manual re-resolution.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
