// MacGlass - shader parameters (Shader > Parameters...).
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LibraBridge

final class ParamsWindowController: NSWindowController {
    private let stack = NSStackView()
    private var parameters: [MGShaderParameter] = []
    private var values: [String: Float] = [:]
    private var sliders: [String: (NSSlider, NSTextField)] = [:]
    var onChange: ((String, Float) -> Void)?
    var onReset: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                              styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: true)
        window.title = "Shader Parameters"
        window.setFrameAutosaveName("MacGlassParameters")
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = flipped
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetClicked))
        reset.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        content.addSubview(reset)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -8),
            reset.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            flipped.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            flipped.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
    }

    func show(presetName: String, parameters: [MGShaderParameter], values: [String: Float]) {
        window?.title = "Shader Parameters - \(presetName)"
        self.parameters = parameters
        self.values = values
        sliders.removeAll()
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if parameters.isEmpty {
            stack.addArrangedSubview(NSTextField(labelWithString: "This shader has no parameters."))
            return
        }
        for p in parameters {
            let value = values[p.name] ?? p.initial
            let label = NSTextField(labelWithString: p.label.trimmingCharacters(in: .whitespaces))
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = p.name
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 230).isActive = true

            let isSeparator = p.minimum == p.maximum
            let slider = NSSlider(value: Double(value), minValue: Double(p.minimum), maxValue: Double(max(p.maximum, p.minimum)),
                                  target: self, action: #selector(sliderMoved(_:)))
            slider.identifier = NSUserInterfaceItemIdentifier(p.name)
            slider.isContinuous = true
            slider.isEnabled = !isSeparator
            if p.step > 0 && p.maximum > p.minimum {
                let ticks = Int(((p.maximum - p.minimum) / p.step).rounded()) + 1
                if ticks >= 2 && ticks <= 41 {
                    slider.numberOfTickMarks = ticks
                    slider.allowsTickMarkValuesOnly = true
                }
            }
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true

            let text = NSTextField(labelWithString: ParamsWindowController.format(value, step: p.step))
            text.alignment = .right
            text.translatesAutoresizingMaskIntoConstraints = false
            text.widthAnchor.constraint(equalToConstant: 56).isActive = true

            let row = NSStackView(views: isSeparator ? [label] : [label, slider, text])
            row.orientation = .horizontal
            row.spacing = 8
            if isSeparator { label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) }
            stack.addArrangedSubview(row)
            sliders[p.name] = (slider, text)
        }
    }

    static func format(_ v: Float, step: Float) -> String {
        if step >= 1 && v == v.rounded() { return String(format: "%.0f", v) }
        if step >= 0.1 { return String(format: "%.2f", v) }
        return String(format: "%.3f", v)
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let name = sender.identifier?.rawValue, let p = parameters.first(where: { $0.name == name }) else { return }
        var v = Float(sender.doubleValue)
        if p.step > 0 { v = p.minimum + ((v - p.minimum) / p.step).rounded() * p.step }
        v = min(max(v, p.minimum), p.maximum)
        values[name] = v
        sliders[name]?.1.stringValue = ParamsWindowController.format(v, step: p.step)
        onChange?(name, v)
    }

    @objc private func resetClicked() {
        onReset?()
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
