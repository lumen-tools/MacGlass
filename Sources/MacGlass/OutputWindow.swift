// MacGlass - output window with a CAMetalLayer.
// SPDX-License-Identifier: GPL-3.0-only
// Portions derived from ShaderGlass (https://github.com/mausimus/ShaderGlass), Copyright (C) 2021-2025 mausimus, GPL-3.0.
// MacGlass is an independent, unofficial project and is not affiliated with ShaderGlass.
import AppKit
import Metal
import QuartzCore

final class OutputView: NSView {
    let metalLayer = CAMetalLayer()
    var onResize: (() -> Void)?
    /// Single-key shortcuts of ShaderGlass (n, r, p, o, space) while the output window has focus.
    var onKey: ((String) -> Bool)?

    init(device: MTLDevice) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.maximumDrawableCount = 2 // less queued frames = lower latency
        metalLayer.displaySyncEnabled = true
        metalLayer.allowsNextDrawableTimeout = true
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let chars = event.charactersIgnoringModifiers?.lowercased(), onKey?(chars) == true { return }
        super.keyDown(with: event)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(1, (bounds.width * scale).rounded()), height: max(1, (bounds.height * scale).rounded()))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
        onResize?()
    }
}

final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Drives rendering from the display refresh (CVDisplayLink).
final class DisplayLinkDriver {
    private var link: CVDisplayLink?
    private let tick: () -> Void

    init(tick: @escaping () -> Void) {
        self.tick = tick
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, context -> CVReturn in
            guard let context else { return kCVReturnSuccess }
            Unmanaged<DisplayLinkDriver>.fromOpaque(context).takeUnretainedValue().tick()
            return kCVReturnSuccess
        }, opaque)
        CVDisplayLinkStart(link)
    }

    func setDisplay(_ id: CGDirectDisplayID) {
        guard let link, id != 0 else { return }
        CVDisplayLinkSetCurrentCGDisplay(link, id)
    }

    deinit {
        if let link { CVDisplayLinkStop(link) }
    }
}
