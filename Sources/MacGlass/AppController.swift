// MacGlass - application controller: input, modes, output window, shaders, profiles.
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import IOKit.pwr_mgt
import LibraBridge
import Metal
import ScreenCaptureKit
import UniformTypeIdentifiers

let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
let projectURL = URL(string: "https://github.com/lumen-tools/MacGlass")!
let defaultPresetKey = "RetroArch/crt/newpixie-crt.slangp" // ShaderGlass' default preset

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    var device: MTLDevice!
    var renderer: Renderer!
    var sink: FrameSink!
    var screenCapture: ScreenCapture!
    var deviceCapture: DeviceCapture!
    let library = ShaderLibrary()
    var window: OutputWindow!
    var view: OutputView!
    var displayLink: DisplayLinkDriver?

    var options = CaptureOptions()
    var running = false
    var firstStart = true
    var librashaderError: String?

    // Shader state
    var currentPreset: PresetEntry?
    var parameters: [MGShaderParameter] = []
    var paramValues: [String: Float] = [:]
    var loadingPreset: String?
    var browser: BrowserWindowController?
    var paramsWindow: ParamsWindowController?

    // Window state
    var captureDisplayID: CGDirectDisplayID = 0
    var fullscreen = false
    var savedFrame: NSRect?
    var menuHidden = false
    var scaleRetained = false
    var lastFrameSize = CGSize.zero
    var lastFPS = (input: 0, output: 0)
    private var captureTask: Task<Void, Never>?
    private var timer: Timer?
    private var ticks = 0
    private var awakeAssertion: IOPMAssertionID = 0
    private var lastChainError: String?
    var waitingForPermission = false
    var permissionHint: NSView?

    // Menus updated dynamically
    var displayMenu = NSMenu(title: "Desktop")
    var windowMenu = NSMenu(title: "Window")
    var deviceMenu = NSMenu(title: "Device")
    var gpuMenu = NSMenu(title: "GPU")
    var recentProfilesMenu = NSMenu(title: "Recent profiles")
    var recentImportsMenu = NSMenu(title: "Recent imports")
    var hotkeysMenu = NSMenu(title: "Global Hotkeys")
    var windowList: [WindowInfo] = []

    let defaults = UserDefaults.standard

    // MARK: - Persistent options (ShaderGlass keeps these in the registry)

    var rememberPosition: Bool {
        get { defaults.bool(forKey: "Remember Position") }
        set { defaults.set(newValue, forKey: "Remember Position") }
    }
    var keepAwake: Bool {
        get { defaults.bool(forKey: "Keep Awake") }
        set { defaults.set(newValue, forKey: "Keep Awake"); updateAwake() }
    }
    var rememberFPS: Bool {
        get { defaults.bool(forKey: "Remember FPS") }
        set { defaults.set(newValue, forKey: "Remember FPS") }
    }

    static var profileDir: URL { ShaderLibrary.appSupportDir() }
    static var defaultProfileURL: URL { profileDir.appendingPathComponent("default.mgp") }

    // MARK: - Startup

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadLibrashader()
        device = AppController.preferredDevice()
        guard let device else {
            fatalAlert("No Metal device was found. MacGlass needs a Mac with Metal support.")
            return
        }
        do {
            renderer = try Renderer(device: device)
        } catch {
            fatalAlert("Metal setup failed: \(error.localizedDescription)")
            return
        }
        renderer.onChainError = { [weak self] message in
            guard let self, self.lastChainError != message else { return }
            self.lastChainError = message
            NSLog("MacGlass: shader error: \(message)")
        }
        sink = FrameSink(device: device, renderer: renderer)
        screenCapture = ScreenCapture(sink: sink)
        screenCapture.onStop = { [weak self] error in self?.captureStopped(error) }
        deviceCapture = DeviceCapture(sink: sink)

        options.bilinear = defaults.bool(forKey: "Bilinear Filter")
        if rememberFPS { options.frameSkipIndex = min(max(0, defaults.integer(forKey: "FPS")), frameSkips.count - 1) }

        createWindow()
        buildMenus()
        HotkeyManager.shared.handler = { [weak self] action in self?.hotkey(action) }
        HotkeyManager.shared.register()
        updateAwake()

        library.rescan()
        if FileManager.default.fileExists(atPath: AppController.defaultProfileURL.path) {
            loadProfile(AppController.defaultProfileURL, startCapture: false)
        } else {
            let key = defaults.string(forKey: "Last Preset") ?? defaultPresetKey
            let values = (defaults.dictionary(forKey: "Last Params") as? [String: Double])?.mapValues { Float($0) } ?? [:]
            if let p = library.preset(forKey: key) ?? library.preset(forKey: defaultPresetKey) ?? library.allPresets.first {
                loadPreset(p, values: key == p.key ? values : [:])
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.onTimer() }
        displayLink = DisplayLinkDriver { [weak self] in self?.renderer?.tick() }
        displayLink?.setDisplay(window.screen?.displayID ?? CGMainDisplayID())

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let error = librashaderError {
            alert("librashader could not be loaded", error + "\n\nShaders are disabled; the captured image is shown without a shader.")
        }

        if case .none = options.input {
            options.input = .display(window.screen?.displayID ?? CGMainDisplayID())
        }
        start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if rememberPosition, !fullscreen {
            defaults.set(NSStringFromRect(window.frame), forKey: "Window Frame")
        }
        if rememberFPS { defaults.set(options.frameSkipIndex, forKey: "FPS") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func loadLibrashader() {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["MACGLASS_LIBRASHADER"] { candidates.append(env) }
        if let fw = Bundle.main.privateFrameworksPath { candidates.append(fw + "/librashader.dylib") }
        let path = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates.last ?? "librashader.dylib"
        librashaderError = MGLibrashader.loadLibrary(path: path)
    }

    static func preferredDevice() -> MTLDevice? {
        if let name = UserDefaults.standard.string(forKey: "GPU"),
           let d = MTLCopyAllDevices().first(where: { $0.name == name }) {
            return d
        }
        return MTLCreateSystemDefaultDevice()
    }

    private func createWindow() {
        view = OutputView(device: device)
        renderer.layer = view.metalLayer
        window = OutputWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        let container = NSView(frame: view.frame)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        let hint = makePermissionHint()
        container.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
        ])
        permissionHint = hint
        window.contentView = container
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenNone, .managed]
        window.title = "MacGlass"
        window.contentMinSize = NSSize(width: 64, height: 48)
        if rememberPosition, let s = defaults.string(forKey: "Window Frame") {
            window.setFrame(NSRectFromString(s), display: false)
        } else {
            window.center()
        }
        view.onResize = { [weak self] in self?.updateRenderParams() }
        view.onKey = { [weak self] key in
            guard let self else { return false }
            switch key {
            case "n": self.nextPreset(random: false)
            case "r": self.nextPreset(random: true)
            case "p": self.nextPixelSize(nil)
            case "o": self.previousPixelSize(nil)
            case " ": self.togglePause(nil)
            default: return false
            }
            return true
        }
    }

    private func makePermissionHint() -> NSView {
        let title = NSTextField(labelWithString: "MacGlass needs permission to record the screen")
        title.font = NSFont.boldSystemFont(ofSize: 15)
        title.textColor = .white
        let text = NSTextField(wrappingLabelWithString:
            "Allow MacGlass in System Settings > Privacy & Security > Screen & System Audio Recording, "
            + "then quit and reopen MacGlass (or choose \"Quit & Reopen\" if macOS offers it) and click Try Again if needed.\n\n"
            + "MacGlass is already switched on there? The entry may belong to an older version: remove MacGlass "
            + "from the list with \"−\", add /Applications/MacGlass.app again with \"+\" and reopen MacGlass.")
        text.textColor = NSColor(white: 0.85, alpha: 1)
        text.alignment = .center
        text.preferredMaxLayoutWidth = 420
        let button = NSButton(title: "Open System Settings", target: self, action: #selector(openScreenRecordingSettings(_:)))
        button.bezelStyle = .rounded
        let retry = NSButton(title: "Try Again", target: self, action: #selector(retryCapture(_:)))
        retry.bezelStyle = .rounded
        retry.keyEquivalent = "\r"
        let buttons = NSStackView(views: [button, retry])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, text, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        stack.layer?.cornerRadius = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        return stack
    }

    // MARK: - Capture

    /// Processing > Start: (re)starts capturing the current input.
    func start() {
        stopInputs()
        let input = options.input
        // No CGPreflightScreenCaptureAccess() gate here: it can report "no access" although access was
        // granted. Capturing is attempted directly; only a refusal by ScreenCaptureKit shows the hint.
        setPermissionHint(visible: false)
        running = true
        firstStart = false
        let prev = captureTask
        captureTask = Task { @MainActor [weak self] in
            await prev?.value
            guard let self else { return }
            do {
                switch input {
                case .none:
                    self.running = false
                case .display(let id):
                    let target = self.options.clone ? id : (self.window.screen?.displayID ?? id)
                    self.captureDisplayID = target
                    try await self.screenCapture.startDisplay(target, showsCursor: self.options.captureCursor,
                                                              maxRate: self.options.maxCaptureRate)
                case .window(let id):
                    try await self.screenCapture.startWindow(id, showsCursor: self.options.captureCursor,
                                                             maxRate: self.options.maxCaptureRate)
                case .device(let uid):
                    try self.deviceCapture.start(uniqueID: uid)
                case .file(let url):
                    let texture = try ImageInput.load(url, device: self.device)
                    self.sink.push(texture: texture)
                }
            } catch CaptureError.permission {
                self.running = false
                self.waitForPermission()
            } catch {
                self.running = false
                self.alert("Could not start capture", error.localizedDescription)
            }
            self.updateWindowMode()
            self.updateTitle()
        }
        updateWindowMode()
    }

    static func needsScreenCapture(_ input: InputKind) -> Bool {
        switch input {
        case .display, .window: return true
        default: return false
        }
    }

    /// No Screen Recording access yet: show a hint in the window and start as soon as access is granted.
    func waitForPermission() {
        running = false
        waitingForPermission = true
        setPermissionHint(visible: true)
        updateWindowMode()
        window?.title = "MacGlass (waiting for Screen Recording permission)"
    }

    func setPermissionHint(visible: Bool) {
        if !visible { waitingForPermission = false }
        permissionHint?.isHidden = !visible
        updateMousePassthrough()
    }

    /// "Try Again" in the permission hint. MacGlass never retries on its own: every attempt without
    /// access can make macOS show its permission dialog again.
    @objc func retryCapture(_ sender: Any?) {
        start()
    }

    @objc func openScreenRecordingSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Processing > Stop.
    func stop() {
        setPermissionHint(visible: false)
        stopInputs()
        running = false
        updateTitle()
    }

    private func stopInputs() {
        deviceCapture?.stop()
        let prev = captureTask
        let capture = screenCapture
        captureTask = Task { @MainActor in
            await prev?.value
            await capture?.stop()
        }
        sink?.flush()
    }

    private func captureStopped(_ error: Error?) {
        running = false
        updateTitle()
        if let error {
            NSLog("MacGlass: capture stopped: \(error.localizedDescription)")
        }
    }

    func setInput(_ input: InputKind) {
        options.input = input
        options.lockedArea = nil
        if case .display = input {} else { options.crop = CropInsets() }
        start()
    }

    var isDesktopInput: Bool {
        if case .display = options.input { return true }
        return false
    }

    var isWindowInput: Bool {
        if case .window = options.input { return true }
        return false
    }

    /// Glass mode on a captured window: the output covers that window.
    var isWindowOverlay: Bool { !options.clone && isWindowInput }

    var isDesktopGlass: Bool { !options.clone && isDesktopInput }

    // MARK: - Window mode

    func updateWindowMode() {
        guard let window else { return }
        let clickThrough = options.transparent || isWindowOverlay || (fullscreen && isDesktopGlass)
        var style: NSWindow.StyleMask
        if fullscreen || isWindowOverlay || menuHidden {
            style = [.borderless, .resizable]
        } else {
            style = [.titled, .closable, .miniaturizable, .resizable]
        }
        if scaleRetained { style.remove(.resizable) }
        if window.styleMask != style {
            let content = window.contentRect(forFrameRect: window.frame)
            window.styleMask = style
            if !fullscreen && !isWindowOverlay {
                window.setFrame(window.frameRect(forContentRect: content), display: true)
            }
        }
        updateMousePassthrough()
        if fullscreen {
            window.level = .statusBar
        } else if clickThrough || options.transparent {
            window.level = .floating
        } else {
            window.level = .normal
        }
        window.hasShadow = !(fullscreen || isWindowOverlay)
        window.isMovableByWindowBackground = menuHidden && !fullscreen
        if fullscreen, let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.frame, display: true)
        }
        updateRenderParams()
        updateTitle()
    }

    func toggleFullscreen() {
        if fullscreen {
            fullscreen = false
            updateWindowMode()
            if let f = savedFrame { window.setFrame(f, display: true) }
        } else {
            savedFrame = window.frame
            fullscreen = true
            updateWindowMode()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Click-through applies to the picture only: the title bar and the window edges stay clickable
    /// (move, resize, close). macOS can only ignore mouse events per window, so this follows the cursor.
    var clickThroughActive: Bool {
        (options.transparent || isWindowOverlay || (fullscreen && isDesktopGlass)) && !waitingForPermission
    }

    func updateMousePassthrough() {
        guard let window else { return }
        var ignore = clickThroughActive
        if ignore && window.styleMask.contains(.titled) {
            // keep the current state while a drag (move / resize) is in progress
            if NSEvent.pressedMouseButtons != 0 && !window.ignoresMouseEvents { return }
            let p = NSEvent.mouseLocation
            let frame = window.frame
            let content = window.contentRect(forFrameRect: frame)
            let edge: CGFloat = 5
            let inTitleBar = frame.contains(p) && p.y >= content.maxY
            let nearEdge = frame.insetBy(dx: -edge, dy: -edge).contains(p) && !frame.insetBy(dx: edge, dy: edge).contains(p)
            if inTitleBar || nearEdge { ignore = false }
        }
        if window.ignoresMouseEvents != ignore { window.ignoresMouseEvents = ignore }
    }

    /// Captured pixels per output pixel scale of the screen the window is on.
    var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    func updateRenderParams() {
        guard let renderer, let window else { return }
        let factors = options.outputScaleFactors
        var p = RenderParams()
        p.inputScale = options.pixelSize * (options.dpiScaling ? Float(backingScale) : 1)
        p.outputScaleW = factors.w
        p.outputScaleH = factors.h
        p.freeScale = options.freeScale || fullscreen || isWindowOverlay
        p.crop = isDesktopInput ? CropInsets() : options.crop
        p.vertical = options.vertical
        p.flipH = options.flipHorizontal
        p.flipV = options.flipVertical
        p.bilinear = options.bilinear
        p.shaderActive = options.shaderActive
        p.frameSkip = options.frameSkip
        p.paused = options.paused
        if isDesktopGlass {
            p.glassOrigin = options.lockedArea?.origin ?? glassOrigin(for: window)
        } else if isDesktopInput, let locked = options.lockedArea {
            p.sourceRegion = locked
        }
        renderer.update { $0 = p }
    }

    /// Top-left of the window content in pixels of the captured display.
    func glassOrigin(for window: NSWindow) -> CGPoint {
        let content = window.contentRect(forFrameRect: window.frame)
        let screen = NSScreen.screens.first { $0.displayID == captureDisplayID } ?? window.screen ?? NSScreen.main
        guard let screen else { return .zero }
        let s = screen.backingScaleFactor
        return CGPoint(x: (content.minX - screen.frame.minX) * s, y: (screen.frame.maxY - content.maxY) * s)
    }

    // MARK: - Timer: window tracking, auto size, title

    private func onTimer() {
        updateMousePassthrough()
        if waitingForPermission {
            ticks += 1
            return
        }
        guard running else {
            ticks += 1
            if ticks % 30 == 0 { updateTitle() }
            return
        }
        // Desktop Glass follows the window to another display.
        if isDesktopGlass, let id = window.screen?.displayID, id != captureDisplayID, options.lockedArea == nil {
            displayLink?.setDisplay(id)
            start()
            return
        }
        if case .window(let id) = options.input {
            if let info = WindowList.window(id) {
                let scale = WindowList.backingScale(for: info.bounds)
                screenCapture.updateSize(width: Int(info.bounds.width * scale), height: Int(info.bounds.height * scale))
                if isWindowOverlay && !fullscreen {
                    let target = WindowList.cocoaRect(info.bounds)
                    if window.frame != target { window.setFrame(target, display: true) }
                    if WindowList.isOnScreen(id) {
                        if !window.isVisible { window.orderFront(nil) }
                    } else if window.isVisible {
                        window.orderOut(nil)
                    }
                }
            } else {
                stop()
                if isWindowOverlay { window.orderFront(nil) }
            }
        }
        // Fixed scale: size the window to the input (ShaderGlass' AdjustWindowSize).
        let size = sink.frameSize
        if size != .zero, !options.freeScale, !fullscreen, !isWindowOverlay, !isDesktopGlass, !scaleRetained {
            let f = options.outputScaleFactors
            var src = size
            if isDesktopInput, let locked = options.lockedArea { src = locked.size }
            if !isDesktopInput {
                src.width = max(1, src.width - CGFloat(options.crop.left + options.crop.right))
                src.height = max(1, src.height - CGFloat(options.crop.top + options.crop.bottom))
            }
            if f.w != 0 && f.h != 0 {
                let target = NSSize(width: (src.width / CGFloat(f.w) / backingScale).rounded(),
                                    height: (src.height / CGFloat(f.h) / backingScale).rounded())
                if size != lastFrameSize || abs(view.bounds.width - target.width) > 1 || abs(view.bounds.height - target.height) > 1 {
                    window.setContentSize(target)
                }
            }
        }
        lastFrameSize = size
        ticks += 1
        if ticks % 30 == 0 {
            lastFPS = renderer.takeStatistics()
            updateTitle()
        }
    }

    func updateTitle() {
        guard let window else { return }
        if let loading = loadingPreset {
            window.title = "MacGlass (loading \(loading)...)"
            return
        }
        guard running else {
            window.title = firstStart ? "MacGlass (no input selected)" : "MacGlass (stopped)"
            return
        }
        var source = ""
        if case .window(let id) = options.input, let info = WindowList.window(id) {
            var t = info.title.isEmpty ? info.owner : info.title
            if let comma = t.firstIndex(of: ",") { t = String(t[..<comma]) }
            if t.count > 20 { t = String(t.prefix(20)) + "..." }
            source = t + ", "
        }
        let shader = options.shaderActive ? (currentPreset?.name ?? "none") : "none"
        let scale = options.freeScale ? "free" : outputScales[options.outputScaleIndex].mnemonic
        let aspect = options.aspectRatioIndex == customAspectIndex ? String(format: "%.2f", options.aspectRatio)
            : aspectRatios[options.aspectRatioIndex].mnemonic
        let fps = options.paused ? "paused" : "\(lastFPS.output)fps"
        window.title = "MacGlass (\(source)\(shader), \(options.pixelSizeMnemonic)px, \(scale)%, ~\(aspect), \(fps))"
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        updateRenderParams()
    }

    func windowDidResize(_ notification: Notification) {
        updateRenderParams()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if let id = window.screen?.displayID { displayLink?.setDisplay(id) }
        view.updateDrawableSize()
    }

    // MARK: - Shaders

    func loadPreset(_ preset: PresetEntry, values: [String: Float] = [:]) {
        guard MGLibrashader.isLoaded() else {
            currentPreset = preset
            return
        }
        let path: URL
        do {
            path = try library.loadablePath(for: preset.url)
        } catch {
            alert("Could not load \(preset.name)", error.localizedDescription)
            return
        }
        loadingPreset = preset.name
        updateTitle()
        renderer.loadPreset(at: path, values: values) { [weak self] result in
            guard let self else { return }
            self.loadingPreset = nil
            switch result {
            case .success(let params):
                self.currentPreset = preset
                self.parameters = params
                let names = Set(params.map { $0.name })
                self.paramValues = values.filter { names.contains($0.key) }
                self.lastChainError = nil
                self.defaults.set(preset.key, forKey: "Last Preset")
                self.saveParams()
                self.paramsWindow?.show(presetName: preset.name, parameters: params, values: self.paramValues)
            case .failure(let error):
                self.alert("Could not load \(preset.name)", error.localizedDescription)
            }
            self.browser?.select(key: self.currentPreset?.key ?? "")
            self.updateTitle()
        }
    }

    func setParameter(_ name: String, _ value: Float) {
        paramValues[name] = value
        renderer.setParameter(name, value: value)
        saveParams()
    }

    func resetParameters() {
        paramValues.removeAll()
        for p in parameters { renderer.setParameter(p.name, value: p.initial) }
        saveParams()
        paramsWindow?.show(presetName: currentPreset?.name ?? "", parameters: parameters, values: [:])
    }

    private func saveParams() {
        defaults.set(paramValues.mapValues { Double($0) }, forKey: "Last Params")
    }

    func nextPreset(random: Bool) {
        let all = library.allPresets
        guard !all.isEmpty else { return }
        var idx: Int
        if random {
            idx = Int.random(in: 0..<all.count)
        } else {
            let cur = all.firstIndex { $0.key == currentPreset?.key } ?? -1
            idx = (cur + 1) % all.count
        }
        loadPreset(all[idx])
    }

    func showBrowser() {
        if browser == nil {
            let b = BrowserWindowController(library: library)
            b.onChoose = { [weak self] p in self?.loadPreset(p) }
            b.onImport = { [weak self] in self?.importCustom() }
            browser = b
        }
        browser?.showWindow(nil)
        browser?.reload(selecting: currentPreset?.key)
    }

    func showParameters() {
        if paramsWindow == nil {
            let w = ParamsWindowController()
            w.onChange = { [weak self] name, value in self?.setParameter(name, value) }
            w.onReset = { [weak self] in self?.resetParameters() }
            paramsWindow = w
        }
        paramsWindow?.show(presetName: currentPreset?.name ?? "", parameters: parameters, values: paramValues)
        paramsWindow?.showWindow(nil)
    }

    func importCustom() {
        let panel = NSOpenPanel()
        panel.title = "Import custom shader"
        panel.message = "Choose a RetroArch preset (.slangp) or shader (.slang). It is copied into the Custom_Shader folder."
        panel.allowedContentTypes = ["slangp", "slang"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importCustom(url)
    }

    func importCustom(_ url: URL) {
        do {
            let preset = try library.importShader(from: url)
            var recent = defaults.stringArray(forKey: "Recent Imports") ?? []
            recent.removeAll { $0 == preset.key }
            recent.insert(preset.key, at: 0)
            defaults.set(Array(recent.prefix(10)), forKey: "Recent Imports")
            browser?.reload(selecting: preset.key)
            loadPreset(preset)
        } catch {
            alert("Import failed", error.localizedDescription)
        }
    }

    // MARK: - Snapshot

    func takeSnapshot(autoSave: Bool) {
        renderer.requestSnapshot { [weak self] image in
            guard let self else { return }
            guard let image else {
                self.alert("Snapshot failed", "There is no output to save yet.")
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let name = "MacGlass \(formatter.string(from: Date())).png"
            var url: URL?
            if autoSave {
                let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory())
                url = dir.appendingPathComponent(name)
            } else {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = name
                if panel.runModal() == .OK { url = panel.url }
            }
            guard let url else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            do {
                try rep.representation(using: .png, properties: [:])?.write(to: url)
            } catch {
                self.alert("Snapshot failed", error.localizedDescription)
            }
        }
    }

    // MARK: - Keep awake

    func updateAwake() {
        if keepAwake {
            if awakeAssertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacGlass Keep Mac Awake" as CFString,
                                            &awakeAssertion)
            }
        } else if awakeAssertion != 0 {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
        }
    }

    // MARK: - Hotkeys

    func hotkey(_ action: HotkeyAction) {
        switch action {
        case .fullscreen: toggleFullscreen()
        case .screenshot: takeSnapshot(autoSave: true)
        case .active: toggleActive(nil)
        case .cursor: toggleCaptureCursor(nil)
        case .pause: running ? stop() : start()
        case .showMenu: toggleMenu(nil)
        case .clickThrough:
            options.transparent.toggle()
            updateWindowMode()
        }
    }

    // MARK: - Profiles

    func makeProfile() -> Profile {
        var p = Profile()
        p.set("ProfileVersion", "1.1")
        p.set("PixelSize", options.pixelSizeMnemonic)
        p.set("DPIScaling", options.dpiScaling ? "1" : "0")
        if options.aspectRatioIndex == customAspectIndex {
            p.set("AspectRatio", String(options.aspectRatio))
        } else {
            p.set("AspectRatio", aspectRatios[options.aspectRatioIndex].mnemonic)
        }
        if let preset = currentPreset {
            if preset.key.hasPrefix("/") { p.set("ShaderPath", preset.key) } else { p.set("Shader", preset.key) }
        }
        p.set("FrameSkip", frameSkips[options.frameSkipIndex].mnemonic)
        p.set("OutputScale", options.freeScale ? "Free" : outputScales[options.outputScaleIndex].mnemonic)
        p.set("FlipH", options.flipHorizontal ? "1" : "0")
        p.set("FlipV", options.flipVertical ? "1" : "0")
        p.set("Vertical", options.vertical ? "1" : "0")
        p.set("Clone", options.clone ? "1" : "0")
        p.set("CaptureCursor", options.captureCursor ? "1" : "0")
        p.set("Transparent", options.transparent ? "1" : "0")
        p.set("ScaleLocked", scaleRetained ? "1" : "0")
        p.set("Bilinear", options.bilinear ? "1" : "0")
        p.set("Active", options.shaderActive ? "1" : "0")
        let c = options.crop
        switch options.input {
        case .display(let id):
            if let s = NSScreen.screens.first(where: { $0.displayID == id }) { p.set("CaptureDisplay", s.displayName) }
            if let l = options.lockedArea {
                p.set("InputArea", "\(Int(l.minX)) \(Int(l.minY)) \(Int(l.maxX)) \(Int(l.maxY))")
            }
        case .window(let id):
            if let w = WindowList.window(id) {
                p.set("CaptureWindow", w.title.isEmpty ? w.owner : w.title)
                p.set("CaptureWindowOwner", w.owner)
            }
            p.set("CroppedArea", "\(c.left) \(c.top) \(c.right) \(c.bottom)")
        case .device(let uid):
            p.set("CaptureDevice", uid)
            p.set("CroppedArea", "\(c.left) \(c.top) \(c.right) \(c.bottom)")
        case .file(let url):
            p.set("ImageFile", url.path)
            p.set("CroppedArea", "\(c.left) \(c.top) \(c.right) \(c.bottom)")
        case .none:
            break
        }
        for (name, value) in paramValues.sorted(by: { $0.key < $1.key }) {
            p.set("Param", "\(name)=\(value)")
        }
        return p
    }

    func saveProfile(_ url: URL) {
        do {
            try makeProfile().save(url)
            addRecentProfile(url)
        } catch {
            alert("Could not save the profile", error.localizedDescription)
        }
    }

    func loadProfile(_ url: URL, startCapture: Bool = true) {
        let p: Profile
        do {
            p = try Profile.load(url)
        } catch {
            alert("Could not load the profile", error.localizedDescription)
            return
        }
        if let v = p["PixelSize"] {
            if let i = pixelSizes.firstIndex(where: { $0.mnemonic == v }) {
                options.pixelSizeIndex = i
                options.customPixelSize = nil
            } else if let c = PixelSizeInfo.parse(v), customPixelSizeRange.contains(c) {
                options.customPixelSize = c
            }
        }
        if let v = p.bool("DPIScaling") { options.dpiScaling = v }
        if let v = p["AspectRatio"] {
            if let i = aspectRatios.firstIndex(where: { $0.mnemonic == v && $0.mnemonic != customMnemonic }) {
                options.aspectRatioIndex = i
            } else if let r = Float(v) {
                aspectRatios[customAspectIndex].ratio = r
                options.aspectRatioIndex = customAspectIndex
            }
        }
        if let v = p["FrameSkip"], let i = frameSkips.firstIndex(where: { $0.mnemonic == v }) { options.frameSkipIndex = i }
        if let v = p["OutputScale"] {
            if v == "Free" { options.freeScale = true } else if let i = outputScales.firstIndex(where: { $0.mnemonic == v }) {
                options.freeScale = false
                options.outputScaleIndex = i
            }
        }
        if let v = p.bool("FlipH") { options.flipHorizontal = v }
        if let v = p.bool("FlipV") { options.flipVertical = v }
        if let v = p.bool("Vertical") { options.vertical = v }
        if let v = p.bool("Clone") { options.clone = v }
        if let v = p.bool("CaptureCursor") { options.captureCursor = v }
        if let v = p.bool("Transparent") { options.transparent = v }
        if let v = p.bool("ScaleLocked") { scaleRetained = v }
        if let v = p.bool("Bilinear") { options.bilinear = v; defaults.set(v, forKey: "Bilinear Filter") }
        if let v = p.bool("Active") { options.shaderActive = v }
        if let v = p["CroppedArea"] {
            let n = v.split(separator: " ").compactMap { Int($0) }
            if n.count == 4 { options.crop = CropInsets(left: n[0], top: n[1], right: n[2], bottom: n[3]) }
        }

        // Input
        options.lockedArea = nil
        if let name = p["CaptureDisplay"] {
            let screen = NSScreen.screens.first { $0.displayName == name } ?? NSScreen.main
            options.input = .display(screen?.displayID ?? CGMainDisplayID())
            if let v = p["InputArea"] {
                let n = v.split(separator: " ").compactMap { Double($0) }
                if n.count == 4, n[2] > n[0], n[3] > n[1] {
                    options.lockedArea = CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
                }
            }
        } else if let title = p["CaptureWindow"] {
            let owner = p["CaptureWindowOwner"]
            let all = WindowList.windows()
            let match = all.first { $0.title == title && (owner == nil || $0.owner == owner) }
                ?? all.first { ($0.title.isEmpty ? $0.owner : $0.title).contains(title) }
            if let match { options.input = .window(match.id) } else {
                alert("Window not found", "The window \"\(title)\" from the profile is not open. Capturing the desktop instead.")
                options.input = .display(CGMainDisplayID())
            }
        } else if let uid = p["CaptureDevice"] {
            options.input = .device(uid)
        } else if let file = p["ImageFile"] {
            options.input = .file(URL(fileURLWithPath: file))
        }

        // Shader and parameters
        var values: [String: Float] = [:]
        for (k, v) in p.entries where k == "Param" {
            let parts = v.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, let f = Float(parts[1]) { values[parts[0]] = f }
        }
        var preset: PresetEntry?
        if let key = p["Shader"] { preset = library.preset(forKey: key) }
        if preset == nil, let path = p["ShaderPath"] { preset = library.preset(forFile: URL(fileURLWithPath: path)) }
        if let preset { loadPreset(preset, values: values) }

        addRecentProfile(url)
        updateWindowMode()
        if startCapture { start() }
    }

    func addRecentProfile(_ url: URL) {
        guard url != AppController.defaultProfileURL else { return }
        var recent = defaults.stringArray(forKey: "Recent Profiles") ?? []
        recent.removeAll { $0 == url.path }
        recent.insert(url.path, at: 0)
        defaults.set(Array(recent.prefix(10)), forKey: "Recent Profiles")
    }

    // MARK: - Dialogs

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        if text.contains("Screen & System Audio Recording") {
            a.addButton(withTitle: "Open System Settings")
            a.addButton(withTitle: "OK")
            if a.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        a.runModal()
    }

    func fatalAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = "MacGlass cannot start"
        a.informativeText = text
        a.runModal()
        NSApp.terminate(nil)
    }

    func cropDialog() {
        let a = NSAlert()
        a.messageText = "Crop"
        a.informativeText = "Pixels to remove from each side of the captured window or device image."
        let fields = (0..<4).map { _ in NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 22)) }
        let c = options.crop
        for (f, v) in zip(fields, [c.left, c.top, c.right, c.bottom]) { f.stringValue = String(v) }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Left:"), fields[0], NSTextField(labelWithString: "Top:"), fields[1]],
            [NSTextField(labelWithString: "Right:"), fields[2], NSTextField(labelWithString: "Bottom:"), fields[3]],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 280, height: 56)
        a.accessoryView = grid
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Reset")
        let r = a.runModal()
        if r == .alertFirstButtonReturn {
            let n = fields.map { max(0, Int($0.stringValue) ?? 0) }
            options.crop = CropInsets(left: n[0], top: n[1], right: n[2], bottom: n[3])
        } else if r == .alertThirdButtonReturn {
            options.crop = CropInsets()
        }
        updateRenderParams()
    }

    func customPixelSizeDialog() {
        let a = NSAlert()
        a.messageText = "Custom Pixel Size"
        a.informativeText = "Captured pixels per pixel of the shader input, with up to two decimals (e.g. 4.65). "
            + "Allowed: \(PixelSizeInfo.format(customPixelSizeRange.lowerBound)) to \(PixelSizeInfo.format(customPixelSizeRange.upperBound))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        field.stringValue = PixelSizeInfo.format(options.pixelSize)
        field.placeholderString = "4.65"
        a.accessoryView = field
        a.window.initialFirstResponder = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let v = PixelSizeInfo.parse(field.stringValue), customPixelSizeRange.contains(v) else {
            alert("Invalid pixel size", "Please enter a number from \(PixelSizeInfo.format(customPixelSizeRange.lowerBound)) "
                  + "to \(PixelSizeInfo.format(customPixelSizeRange.upperBound)), with up to two decimals (e.g. 4.65).")
            return
        }
        if let i = pixelSizes.firstIndex(where: { abs($0.size - v) < 0.001 }) {
            options.pixelSizeIndex = i
            options.customPixelSize = nil
        } else {
            options.customPixelSize = v
        }
        updateRenderParams()
        updateTitle()
    }

    func customAspectDialog() {
        let a = NSAlert()
        a.messageText = "Custom Aspect Ratio"
        a.informativeText = "Horizontal stretch factor of a source pixel (e.g. 1.2 for DOS/NTSC, 0.8 for NES)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        field.stringValue = String(aspectRatios[customAspectIndex].ratio)
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn, let v = Float(field.stringValue.replacingOccurrences(of: ",", with: ".")), v > 0 {
            aspectRatios[customAspectIndex].ratio = v
            options.aspectRatioIndex = customAspectIndex
            updateRenderParams()
        }
    }
}
