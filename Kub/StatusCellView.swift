import AppKit

/// Borderless mini-button embedded in a table row (Delete / Restart).
final class MiniActionCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("MiniActionCell")
    private let button = NSButton()
    private var handler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = #selector(clicked)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configure(symbol: String, tooltip: String, tint: NSColor, handler: @escaping () -> Void) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(cfg)
        button.contentTintColor = tint
        button.toolTip = tooltip
        self.handler = handler
    }

    @objc private func clicked() { handler?() }
}

/// Categorical colors for CPU architectures — distinct hues so amd64 / arm64
/// can't be misread as each other. Blue/orange is a colorblind-safe pair.
enum ArchBadge {
    static func color(for arch: String) -> NSColor {
        switch arch.lowercased() {
        case "amd64", "x86_64", "x86-64": return .systemBlue
        case "arm64", "aarch64":          return .systemOrange
        case "arm", "armv7", "armv6":     return .systemYellow
        case "386", "i386", "x86":        return .systemTeal
        case "ppc64le", "ppc64":          return .systemPink
        case "s390x":                     return .systemPurple
        default:                          return .systemGray
        }
    }
}

/// A small colored capsule label (node architecture: amd64 / arm64 / …).
final class BadgeCellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("BadgeCell")

    private let pill = NSView()
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .clear
    private var filled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerCurve = .continuous
        pill.layer?.cornerRadius = 5

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        pill.addSubview(label)
        addSubview(pill)
        self.textField = label

        let trailing = pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 16),
            trailing,
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configure(_ text: String, color: NSColor) {
        if text.isEmpty || text == "—" {   // unknown → quiet dash, no pill
            filled = false
            label.stringValue = "—"
        } else {
            filled = true
            tint = color
            label.stringValue = text
        }
        apply()
    }

    /// On a selected + emphasized row the colored pill clashes with the highlight —
    /// drop the pill and show plain white text, like the row's other cells.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { apply() }
    }

    /// cgColor is a snapshot of the current appearance — re-resolve on light/dark switch.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        let selected = backgroundStyle == .emphasized
        let bg: NSColor
        if !filled {
            label.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            bg = .clear
        } else if selected {
            label.textColor = .alternateSelectedControlTextColor   // white on the selection highlight
            bg = .clear                                            // no pill on the selected row
        } else {
            label.textColor = tint
            bg = tint.withAlphaComponent(0.16)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.layer?.backgroundColor = bg.cgColor
        }
    }
}

/// Reusable table cell: optional SF Symbol indicator + a single text label.
/// Used for the status/name column (with icon) and plain columns (icon collapsed).
final class StatusCellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("StatusCell")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var iconWidth: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.font = .systemFont(ofSize: 12)

        addSubview(icon)
        addSubview(label)
        self.imageView = icon
        self.textField = label

        iconWidth = icon.widthAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Icon + text (status / name column).
    func configure(kind: StatusKind, text: String, bold: Bool = false) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: text)?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = kind.color
        icon.isHidden = false
        iconWidth.constant = 16
        label.alignment = .natural
        label.stringValue = text
        label.textColor = .labelColor
        label.font = bold ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12)
    }

    /// Namespace value — bolder + dimmer than plain text (matches the group header).
    func configureNamespace(_ text: String) {
        icon.isHidden = true
        iconWidth.constant = 0
        label.alignment = .natural
        label.stringValue = text
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12, weight: .semibold)
    }

    /// Plain text, no icon (numeric columns are right-aligned).
    func configurePlain(_ text: String, monospacedDigits: Bool = false,
                        secondary: Bool = false, alignment: NSTextAlignment = .natural) {
        icon.isHidden = true
        iconWidth.constant = 0
        label.alignment = alignment
        label.stringValue = text
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.font = monospacedDigits
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
    }
}
