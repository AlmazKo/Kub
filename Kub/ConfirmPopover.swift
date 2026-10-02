import AppKit

enum ConfirmResult { case cancelled; case confirmed(Int?) }

/// A lightweight popover that replaces system alerts for confirmations: a
/// title, an aligned detail grid, an optional colored warning, a note, and an
/// optional integer stepper (replicas / duration). Anchored to the triggering
/// row or view; transient (clicking away cancels). Async result via `onResult`.
@MainActor
final class ConfirmPopover: NSViewController, NSPopoverDelegate, NSTextFieldDelegate {
    struct Stepper {
        let label: String, unit: String?
        let value: Int, min: Int, max: Int, step: Int
        let presets: [Int]
    }

    private static var active: ConfirmPopover?

    private let popover = NSPopover()
    private var onResult: ((ConfirmResult) -> Void)?
    private var stepperControl: StepperControl?
    private var contentView: NSView!
    private var finished = false
    /// Builds the exact command to run from the current stepper value (nil = no stepper).
    private var commandBuilder: ((Int?) -> String)?
    private var commandLabel: NSTextField?
    /// Type-to-confirm gate for data-loss deletes: the confirm button stays disabled
    /// until the field matches `requiredTyped` exactly (nil → no gate).
    private var requiredTyped: String?
    private var typedField: NSTextField?
    private weak var confirmButton: NSButton?

    static func present(
        from anchor: NSView, rect: NSRect, preferredEdge: NSRectEdge = .maxX,
        title: String, detail: [(String, String, NSColor?)] = [],
        warning: (text: String, color: NSColor)? = nil, note: String? = nil,
        confirmTitle: String, cancelTitle: String? = "Cancel", danger: Bool,
        destructive: Bool = false,
        requireTyped: String? = nil,
        stepper: Stepper? = nil, command: ((Int?) -> String)? = nil,
        onResult: @escaping (ConfirmResult) -> Void
    ) {
        active?.finish(.cancelled)
        let vc = ConfirmPopover()
        vc.onResult = onResult
        vc.build(title: title, detail: detail, warning: warning, note: note,
                 confirmTitle: confirmTitle, cancelTitle: cancelTitle, danger: danger,
                 destructive: destructive, requireTyped: requireTyped, stepper: stepper, command: command)
        vc.popover.contentViewController = vc
        vc.popover.behavior = .transient
        vc.popover.animates = false   // replace the slow built-in inflate with a quick custom fade
        vc.popover.delegate = vc
        active = vc
        vc.view.layer?.opacity = 0    // pre-hide so no fully-opaque frame paints before the fade
        vc.popover.show(relativeTo: rect, of: anchor, preferredEdge: preferredEdge)
        vc.fadeInContent()
        // Focus the type-to-confirm field if present, else the stepper field.
        if let field = vc.typedField ?? vc.stepperControl?.firstField {
            vc.view.window?.makeFirstResponder(field)
        }
    }

    /// Snappy ~90ms ease-out fade of the content layer. The built-in popover
    /// animation is off (`animates = false`) and has no duration API, so we fade
    /// only the content layer — the system-drawn body, beak and shadow are left
    /// intact. `wantsLayer` is set in `build()` so `view.layer` exists for the
    /// pre-hide above; here we animate it back up and commit the model value.
    private func fadeInContent() {
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.09
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "snappyShow")
        layer.opacity = 1
    }

    override func loadView() { view = contentView }

    private func build(title: String, detail: [(String, String, NSColor?)],
                       warning: (text: String, color: NSColor)?, note: String?,
                       confirmTitle: String, cancelTitle: String?, danger: Bool,
                       destructive: Bool, requireTyped: String?, stepper: Stepper?, command: ((Int?) -> String)?) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(titleLabel)

        if !detail.isEmpty {
            let grid = NSGridView(views: detail.map { [keyLabel($0.0), valueLabel($0.1, color: $0.2)] })
            grid.column(at: 0).xPlacement = .trailing
            grid.rowSpacing = 4
            grid.columnSpacing = 10
            stack.addArrangedSubview(grid)
        }
        if let warning {
            stack.addArrangedSubview(warningRow(warning.text, color: warning.color))
        }
        if let note {
            stack.addArrangedSubview(noteLabel(note))
        }
        if let stepper {
            let control = StepperControl(label: stepper.label, unit: stepper.unit, value: stepper.value,
                                         min: stepper.min, max: stepper.max, step: stepper.step, presets: stepper.presets)
            stepperControl = control
            stack.addArrangedSubview(control.view)
        }
        if let command {
            commandBuilder = command
            stack.addArrangedSubview(commandBox())
            stepperControl?.onChange = { [weak self] in self?.updateCommand() }
            updateCommand()
        }
        if let requireTyped {
            requiredTyped = requireTyped
            stack.addArrangedSubview(typedConfirmField(placeholder: requireTyped))
        }

        let cancelButton: NSButton?
        if let cancelTitle {
            let b = NSButton(title: cancelTitle, target: self, action: #selector(cancelClicked))
            // Dangerous action → Return defaults to the safe choice (Cancel).
            b.keyEquivalent = danger ? "\r" : "\u{1b}"
            cancelButton = b
        } else {
            cancelButton = nil
        }
        let confirmButton = NSButton(title: confirmTitle, target: self, action: #selector(confirmClicked))
        confirmButton.hasDestructiveAction = danger
        confirmButton.keyEquivalent = danger ? "" : "\r"
        confirmButton.isEnabled = (requireTyped == nil)   // gated by the type-to-confirm field
        if destructive {   // a delete → a red confirm button with white title
            confirmButton.bezelColor = .systemRed
            confirmButton.attributedTitle = NSAttributedString(string: confirmTitle, attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            ])
        }
        self.confirmButton = confirmButton

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var buttonViews: [NSView] = [spacer]
        if let cancelButton { buttonViews.append(cancelButton) }
        buttonViews.append(confirmButton)
        let buttonRow = NSStackView(views: buttonViews)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true   // backing layer must exist for the pre-hide + fade-in
        // Opaque fill so the popover isn't see-through over the table behind it
        // (NSPopover's default material is translucent).
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        container.addSubview(stack)
        container.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttonRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 14),
            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            container.widthAnchor.constraint(equalToConstant: 320),
        ])
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(x: 0, y: 0, width: 320, height: container.fittingSize.height)
        contentView = container
    }

    @objc private func cancelClicked() { finish(.cancelled) }
    @objc private func confirmClicked() { finish(.confirmed(stepperControl?.value)) }

    func popoverDidClose(_ notification: Notification) { finish(.cancelled) }

    private func finish(_ result: ConfirmResult) {
        guard !finished else { return }
        finished = true
        let callback = onResult
        onResult = nil
        if ConfirmPopover.active === self { ConfirmPopover.active = nil }
        popover.performClose(nil)
        callback?(result)
    }

    // MARK: - Content helpers

    private func keyLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func valueLabel(_ s: String, color: NSColor? = nil) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.textColor = color ?? .labelColor
        l.isSelectable = true
        l.lineBreakMode = .byTruncatingMiddle
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        l.toolTip = s
        return l
    }

    private func warningRow(_ text: String, color: NSColor) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = color
        let row = NSStackView(views: [icon, l])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    /// A monospaced "code block" showing the exact command that will run.
    private func commandBox() -> NSView {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .labelColor
        label.isSelectable = true
        label.drawsBackground = false
        label.preferredMaxLayoutWidth = 270
        label.translatesAutoresizingMaskIntoConstraints = false
        commandLabel = label

        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerCurve = .continuous
        box.layer?.cornerRadius = 5
        box.layer?.borderWidth = 1
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            box.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor   // clean code-field look
            box.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
            box.widthAnchor.constraint(equalToConstant: 288),
        ])
        return box
    }

    private func updateCommand() {
        commandLabel?.stringValue = commandBuilder?(stepperControl?.value) ?? ""
    }

    /// A "type the name to confirm" gate for irreversible, data-loss deletes.
    private func typedConfirmField(placeholder: String) -> NSView {
        let caption = NSTextField(labelWithString: "Type the name to confirm:")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let field = NSTextField(string: "")
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 288).isActive = true
        typedField = field

        let v = NSStackView(views: [caption, field])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 4
        return v
    }

    /// Enable the confirm button only when the typed name matches exactly.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === typedField else { return }
        confirmButton?.isEnabled = field.stringValue == requiredTyped
    }

    private func noteLabel(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.preferredMaxLayoutWidth = 288
        return l
    }
}

/// A labeled integer picker: field + stepper + quick presets, kept in sync.
@MainActor
final class StepperControl: NSObject, NSTextFieldDelegate {
    let view: NSView
    let firstField: NSTextField
    private let field = NSTextField(string: "")
    private let stepper = NSStepper()
    private let presets: [Int]
    private let lo: Int
    private let hi: Int

    /// Fired whenever the value changes (stepper, preset, or typing) — for the live command preview.
    var onChange: (() -> Void)?

    var value: Int { min(hi, max(lo, Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? lo)) }

    init(label: String, unit: String?, value def: Int, min lo: Int, max hi: Int, step: Int, presets: [Int]) {
        self.presets = presets
        self.lo = lo
        self.hi = hi
        firstField = field

        field.integerValue = def
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true

        stepper.minValue = Double(lo)
        stepper.maxValue = Double(hi)
        stepper.increment = Double(step)
        stepper.integerValue = def
        stepper.valueWraps = false

        let caption = NSTextField(labelWithString: label)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        var fieldViews: [NSView] = [caption, field, stepper]
        if let unit {
            let unitLabel = NSTextField(labelWithString: unit)
            unitLabel.font = .systemFont(ofSize: 11)
            unitLabel.textColor = .secondaryLabelColor
            fieldViews.append(unitLabel)
        }
        let fieldRow = NSStackView(views: fieldViews)
        fieldRow.orientation = .horizontal
        fieldRow.spacing = 6
        fieldRow.alignment = .centerY

        let presetControl = NSSegmentedControl(
            labels: presets.map(String.init), trackingMode: .momentary, target: nil, action: nil)
        presetControl.segmentStyle = .rounded

        let v = NSStackView(views: [fieldRow, presetControl])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 6
        view = v

        super.init()
        field.delegate = self   // live command preview while typing
        stepper.target = self
        stepper.action = #selector(stepped)
        presetControl.target = self
        presetControl.action = #selector(presetPicked(_:))
    }

    @objc private func stepped() { field.integerValue = stepper.integerValue; onChange?() }

    @objc private func presetPicked(_ sender: NSSegmentedControl) {
        let i = sender.selectedSegment
        guard i >= 0, i < presets.count else { return }
        field.integerValue = presets[i]
        stepper.integerValue = presets[i]
        onChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        if let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) {
            stepper.integerValue = min(hi, max(lo, v))
        }
        onChange?()
    }
}
