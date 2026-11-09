// MacGlass - menu bar, modelled on ShaderGlass' menus (Processing, Input, Output, Shader, Help).
// SPDX-License-Identifier: GPL-3.0-only
// Portions derived from ShaderGlass (https://github.com/mausimus/ShaderGlass), Copyright (C) 2021-2025 mausimus, GPL-3.0.
// MacGlass is an independent, unofficial project and is not affiliated with ShaderGlass.
import AppKit
import AVFoundation
import Metal
import UniformTypeIdentifiers

extension AppController: NSMenuItemValidation {

    // MARK: - Building

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, key: String = "",
                     mods: NSEvent.ModifierFlags = [], tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = action == nil ? nil : self
        item.tag = tag
        menu.addItem(item)
        return item
    }

    private func submenu(_ menu: NSMenu, _ title: String, _ sub: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
    }

    private func disabled(_ menu: NSMenu, _ title: String, checked: Bool = false) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    func buildMenus() {
        let main = NSMenu()

        // Application menu
        let app = NSMenu(title: "MacGlass")
        app.addItem(withTitle: "About MacGlass", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide MacGlass", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit MacGlass", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        submenu(main, "MacGlass", app)

        // Edit (for text fields in dialogs)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        submenu(main, "Edit", edit)

        // Processing
        let processing = NSMenu(title: "Processing")
        add(processing, "Start", #selector(menuStart(_:)))
        add(processing, "Stop", #selector(menuStop(_:)))
        add(processing, "Pause/Unpause  (space)", #selector(togglePause(_:)))
        hotkeysMenu.delegate = self
        submenu(processing, "Global Hotkeys", hotkeysMenu)
        add(processing, "Toggle Menu", #selector(toggleMenu(_:)))
        add(processing, "Remember Position", #selector(toggleRememberPosition(_:)))
        add(processing, "Keep Mac Awake", #selector(toggleKeepAwake(_:)))
        add(processing, "Bilinear Filter", #selector(toggleBilinear(_:)))
        processing.addItem(.separator())
        gpuMenu.delegate = self
        submenu(processing, "GPU", gpuMenu)
        let rendererMenu = NSMenu(title: "Renderer")
        disabled(rendererMenu, "Metal", checked: true)
        submenu(processing, "Renderer", rendererMenu)
        let fps = NSMenu(title: "FPS")
        add(fps, "Remember FPS", #selector(toggleRememberFPS(_:)))
        fps.addItem(.separator())
        for (i, f) in frameSkips.enumerated() { add(fps, f.text, #selector(selectFrameSkip(_:)), tag: i) }
        submenu(processing, "FPS", fps)
        let advanced = NSMenu(title: "Advanced")
        add(advanced, "Allow Tearing", #selector(toggleAllowTearing(_:)))
        add(advanced, "Max Capture Rate", #selector(toggleMaxCaptureRate(_:)))
        submenu(processing, "Advanced", advanced)
        processing.addItem(.separator())
        add(processing, "Load profile...", #selector(loadProfileMenu(_:)), key: "o", mods: [.command])
        add(processing, "Save profile as...", #selector(saveProfileMenu(_:)), key: "s", mods: [.command])
        recentProfilesMenu.delegate = self
        submenu(processing, "Recent profiles", recentProfilesMenu)
        processing.addItem(.separator())
        add(processing, "Set as default profile", #selector(setDefaultProfile(_:)))
        add(processing, "Remove default profile", #selector(removeDefaultProfile(_:)))
        submenu(main, "Processing", processing)

        // Input
        let input = NSMenu(title: "Input")
        displayMenu.delegate = self
        submenu(input, "Desktop", displayMenu)
        windowMenu.delegate = self
        submenu(input, "Window", windowMenu)
        deviceMenu.delegate = self
        submenu(input, "Device", deviceMenu)
        add(input, "File...", #selector(chooseFile(_:)))
        input.addItem(.separator())
        let pixel = NSMenu(title: "Pixel Size")
        add(pixel, "Next  (p)", #selector(nextPixelSize(_:)))
        add(pixel, "Previous  (o)", #selector(previousPixelSize(_:)))
        add(pixel, "Adjust for Retina Scale", #selector(toggleDPIScaling(_:)))
        for (i, p) in pixelSizes.enumerated() { add(pixel, p.text, #selector(selectPixelSize(_:)), tag: i) }
        add(pixel, "Custom...", #selector(customPixelSizeMenu(_:)))
        submenu(input, "Pixel Size", pixel)
        add(input, "Crop...", #selector(cropMenu(_:)))
        add(input, "Capture Cursor", #selector(toggleCaptureCursor(_:)))
        submenu(main, "Input", input)

        // Output
        let output = NSMenu(title: "Output")
        let mode = NSMenu(title: "Mode")
        add(mode, "Glass", #selector(selectGlass(_:)))
        add(mode, "Clone", #selector(selectClone(_:)))
        submenu(output, "Mode", mode)
        let win = NSMenu(title: "Window")
        add(win, "Solid", #selector(selectSolid(_:)))
        add(win, "Click-through", #selector(selectClickThrough(_:)))
        submenu(output, "Window", win)
        let flip = NSMenu(title: "Flip")
        add(flip, "Horizontal", #selector(toggleFlipH(_:)))
        add(flip, "Vertical", #selector(toggleFlipV(_:)))
        submenu(output, "Flip", flip)
        let scale = NSMenu(title: "Scale")
        add(scale, "Free", #selector(selectFreeScale(_:)))
        for (i, s) in outputScales.enumerated() { add(scale, s.text, #selector(selectOutputScale(_:)), tag: i) }
        add(scale, "Retain", #selector(toggleRetainScale(_:)))
        submenu(output, "Scale", scale)
        let aspect = NSMenu(title: "Aspect Ratio Correction")
        for (i, a) in aspectRatios.enumerated() { add(aspect, a.text, #selector(selectAspectRatio(_:)), tag: i) }
        submenu(output, "Aspect Ratio Correction", aspect)
        let orientation = NSMenu(title: "Orientation")
        add(orientation, "Horizontal", #selector(selectHorizontal(_:)))
        add(orientation, "Vertical", #selector(selectVertical(_:)))
        submenu(output, "Orientation", orientation)
        add(output, "Fullscreen", #selector(fullscreenMenu(_:)), key: "g", mods: [.control, .shift])
        output.addItem(.separator())
        add(output, "Take Snapshot...", #selector(snapshotMenu(_:)))
        submenu(main, "Output", output)

        // Shader
        let shader = NSMenu(title: "Shader")
        add(shader, "Choose from Library...", #selector(chooseFromLibrary(_:)), key: "l", mods: [.command])
        shader.addItem(.separator())
        add(shader, "Next  (n)", #selector(nextShader(_:)))
        add(shader, "Random  (r)", #selector(randomShader(_:)))
        add(shader, "Active", #selector(toggleActive(_:)))
        shader.addItem(.separator())
        add(shader, "Import custom...", #selector(importMenu(_:)))
        recentImportsMenu.delegate = self
        submenu(shader, "Recent imports", recentImportsMenu)
        shader.addItem(.separator())
        add(shader, "Parameters...", #selector(parametersMenu(_:)), key: "k", mods: [.command])
        submenu(main, "Shader", shader)

        // Help
        let help = NSMenu(title: "Help")
        disabled(help, "MacGlass v\(appVersion)")
        disabled(help, "Unofficial, based on ShaderGlass by mausimus")
        add(help, "github.com/lumen-tools/MacGlass", #selector(openProject(_:)))
        add(help, "Online Manual", #selector(openManual(_:)))
        submenu(main, "Help", help)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    // MARK: - Dynamic submenus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === displayMenu {
            for (i, screen) in NSScreen.screens.enumerated() {
                let item = add(menu, "\(screen.displayName) (\(Int(screen.frame.width))x\(Int(screen.frame.height)))",
                               #selector(selectDisplay(_:)), tag: i)
                if case .display(let id) = options.input, id == screen.displayID { item.state = .on }
            }
            menu.addItem(.separator())
            add(menu, "Lock Current Area", #selector(toggleLockArea(_:)))
        } else if menu === windowMenu {
            windowList = WindowList.windows()
            if windowList.isEmpty { disabled(menu, "No windows found") }
            for (i, w) in windowList.enumerated() {
                let item = add(menu, w.menuTitle, #selector(selectWindow(_:)), tag: i)
                if case .window(let id) = options.input, id == w.id { item.state = .on }
            }
        } else if menu === deviceMenu {
            let devices = DeviceCapture.devices()
            if devices.isEmpty { disabled(menu, "No devices found") }
            for d in devices {
                let item = add(menu, d.localizedName, #selector(selectDevice(_:)))
                item.representedObject = d.uniqueID
                if case .device(let uid) = options.input, uid == d.uniqueID { item.state = .on }
            }
        } else if menu === gpuMenu {
            let current = device?.name
            let item = add(menu, "Default", #selector(selectGPU(_:)))
            item.state = defaults.string(forKey: "GPU") == nil ? .on : .off
            for d in MTLCopyAllDevices() {
                let i = add(menu, d.name, #selector(selectGPU(_:)))
                i.representedObject = d.name
                if defaults.string(forKey: "GPU") == d.name { i.state = .on }
            }
            if let current { disabled(menu, "In use: \(current)") }
        } else if menu === recentProfilesMenu {
            let recent = defaults.stringArray(forKey: "Recent Profiles") ?? []
            if recent.isEmpty { disabled(menu, "None") }
            for path in recent {
                let item = add(menu, (path as NSString).lastPathComponent, #selector(openRecentProfile(_:)))
                item.representedObject = path
                item.toolTip = path
            }
        } else if menu === recentImportsMenu {
            let recent = recentImports
            if recent.isEmpty { disabled(menu, "None") }
            for path in recent {
                let item = add(menu, path, #selector(openRecentImport(_:)))
                item.representedObject = path
            }
        } else if menu === hotkeysMenu {
            add(menu, "Enable", #selector(toggleHotkeys(_:)))
            for (i, action) in HotkeyAction.allCases.enumerated() {
                let key = HotkeyManager.shared.key(for: action)?.display ?? "none"
                add(menu, "\(action.title)  (\(key))", #selector(editHotkey(_:)), tag: i)
            }
        }
    }

    // MARK: - Check marks

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        func on(_ b: Bool) { item.state = b ? .on : .off }
        switch item.action {
        case #selector(menuStart(_:)): return !running
        case #selector(menuStop(_:)): return running
        case #selector(togglePause(_:)): on(options.paused)
        case #selector(toggleMenu(_:)): on(menuHidden)
        case #selector(toggleRememberPosition(_:)): on(rememberPosition)
        case #selector(toggleKeepAwake(_:)): on(keepAwake)
        case #selector(toggleBilinear(_:)): on(options.bilinear)
        case #selector(toggleRememberFPS(_:)): on(rememberFPS)
        case #selector(selectFrameSkip(_:)): on(item.tag == options.frameSkipIndex)
        case #selector(toggleAllowTearing(_:)): on(allowTearing)
        case #selector(toggleMaxCaptureRate(_:)): on(options.maxCaptureRate)
        case #selector(removeDefaultProfile(_:)):
            return FileManager.default.fileExists(atPath: AppController.defaultProfileURL.path)
        case #selector(toggleLockArea(_:)):
            on(options.lockedArea != nil)
            return isDesktopInput
        case #selector(toggleDPIScaling(_:)):
            item.title = "Adjust for Retina Scale (\(Int(backingScale * 100))%)"
            on(options.dpiScaling)
            return backingScale != 1
        case #selector(selectPixelSize(_:)): on(options.customPixelSize == nil && item.tag == options.pixelSizeIndex)
        case #selector(customPixelSizeMenu(_:)):
            item.title = options.customPixelSize.map { "Custom (x\(PixelSizeInfo.format($0)))..." } ?? "Custom..."
            on(options.customPixelSize != nil)
        case #selector(cropMenu(_:)): return !isDesktopInput
        case #selector(toggleCaptureCursor(_:)): on(options.captureCursor)
        case #selector(selectGlass(_:)): on(!options.clone)
        case #selector(selectClone(_:)): on(options.clone)
        case #selector(selectSolid(_:)): on(!options.transparent)
        case #selector(selectClickThrough(_:)): on(options.transparent)
        case #selector(toggleFlipH(_:)): on(options.flipHorizontal)
        case #selector(toggleFlipV(_:)): on(options.flipVertical)
        case #selector(selectFreeScale(_:)): on(options.freeScale)
        case #selector(selectOutputScale(_:)): on(!options.freeScale && item.tag == options.outputScaleIndex)
        case #selector(toggleRetainScale(_:)): on(scaleRetained)
        case #selector(selectAspectRatio(_:)):
            if item.tag == customAspectIndex {
                item.title = options.aspectRatioIndex == customAspectIndex
                    ? String(format: "Custom (x%.2f)...", options.aspectRatio) : "Custom..."
            }
            on(item.tag == options.aspectRatioIndex)
        case #selector(selectHorizontal(_:)): on(!options.vertical)
        case #selector(selectVertical(_:)): on(options.vertical)
        case #selector(fullscreenMenu(_:)): on(fullscreen)
        case #selector(toggleActive(_:)): on(options.shaderActive)
        case #selector(toggleHotkeys(_:)): on(HotkeyManager.shared.enabled)
        default: break
        }
        return true
    }

    // MARK: - Processing actions

    @objc func menuStart(_ sender: Any?) { start() }
    @objc func menuStop(_ sender: Any?) { stop() }

    @objc func togglePause(_ sender: Any?) {
        options.paused.toggle()
        updateRenderParams()
        updateTitle()
    }

    @objc func toggleMenu(_ sender: Any?) {
        menuHidden.toggle()
        updateWindowMode()
    }

    @objc func toggleRememberPosition(_ sender: Any?) { rememberPosition.toggle() }
    @objc func toggleKeepAwake(_ sender: Any?) { keepAwake.toggle() }

    @objc func toggleBilinear(_ sender: Any?) {
        options.bilinear.toggle()
        defaults.set(options.bilinear, forKey: "Bilinear Filter")
        updateRenderParams()
    }

    @objc func toggleRememberFPS(_ sender: Any?) { rememberFPS.toggle() }

    @objc func selectFrameSkip(_ sender: NSMenuItem) {
        options.frameSkipIndex = sender.tag
        if rememberFPS { defaults.set(sender.tag, forKey: "FPS") }
        updateRenderParams()
    }

    @objc func toggleAllowTearing(_ sender: Any?) {
        allowTearing.toggle()
        updateTitle()
    }

    @objc func toggleMaxCaptureRate(_ sender: Any?) {
        options.maxCaptureRate.toggle()
        if running { start() }
    }

    @objc func selectGPU(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String {
            defaults.set(name, forKey: "GPU")
        } else {
            defaults.removeObject(forKey: "GPU")
        }
        alert("GPU changed", "Restart MacGlass to use the selected GPU.")
    }

    @objc func toggleHotkeys(_ sender: Any?) {
        HotkeyManager.shared.enabled.toggle()
    }

    @objc func editHotkey(_ sender: NSMenuItem) {
        let action = HotkeyAction.allCases[sender.tag]
        let manager = HotkeyManager.shared
        switch HotkeyRecorderView.runDialog(title: action.name, current: manager.key(for: action)) {
        case .set(let key): manager.setKey(key, for: action)
        case .reset:
            defaults.removeObject(forKey: "Hotkey \(action.rawValue)")
            manager.register()
        case .cancel: break
        }
    }

    @objc func loadProfileMenu(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Load profile"
        panel.allowedContentTypes = [UTType(filenameExtension: "mgp")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { loadProfile(url) }
    }

    @objc func saveProfileMenu(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Save profile as"
        panel.nameFieldStringValue = (currentPreset?.name ?? "MacGlass") + ".mgp"
        panel.allowedContentTypes = [UTType(filenameExtension: "mgp")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url { saveProfile(url) }
    }

    @objc func openRecentProfile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        loadProfile(URL(fileURLWithPath: path))
    }

    @objc func setDefaultProfile(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: AppController.profileDir, withIntermediateDirectories: true)
        do {
            try makeProfile().save(AppController.defaultProfileURL)
        } catch {
            alert("Could not save the default profile", error.localizedDescription)
        }
    }

    @objc func removeDefaultProfile(_ sender: Any?) {
        try? FileManager.default.removeItem(at: AppController.defaultProfileURL)
    }

    // MARK: - Input actions

    @objc func selectDisplay(_ sender: NSMenuItem) {
        guard sender.tag < NSScreen.screens.count else { return }
        let screen = NSScreen.screens[sender.tag]
        if !options.clone && !fullscreen {
            // Desktop Glass shows the area under the window: move the window to that display.
            let frame = window.frame
            if window.screen?.displayID != screen.displayID {
                let vf = screen.visibleFrame
                window.setFrame(NSRect(x: vf.midX - frame.width / 2, y: vf.midY - frame.height / 2,
                                       width: min(frame.width, vf.width), height: min(frame.height, vf.height)), display: true)
            }
        }
        setInput(.display(screen.displayID))
    }

    @objc func toggleLockArea(_ sender: Any?) {
        if options.lockedArea != nil {
            options.lockedArea = nil
        } else {
            let origin = glassOrigin(for: window)
            let f = options.outputScaleFactors
            let px = view.metalLayer.drawableSize
            options.lockedArea = CGRect(x: origin.x, y: origin.y,
                                        width: px.width * CGFloat(f.w == 0 ? 1 : f.w), height: px.height * CGFloat(f.h == 0 ? 1 : f.h))
        }
        updateRenderParams()
    }

    @objc func selectWindow(_ sender: NSMenuItem) {
        guard sender.tag < windowList.count else { return }
        setInput(.window(windowList[sender.tag].id))
    }

    @objc func selectDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        setInput(.device(uid))
    }

    @objc func chooseFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose an image"
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { setInput(.file(url)) }
    }

    @objc func nextPixelSize(_ sender: Any?) {
        if let c = options.customPixelSize {
            // from a custom size to the next larger preset size
            options.pixelSizeIndex = pixelSizes.firstIndex { $0.size > c } ?? 0
            options.customPixelSize = nil
        } else {
            options.pixelSizeIndex = (options.pixelSizeIndex + 1) % pixelSizes.count
        }
        updateRenderParams()
        updateTitle()
    }

    @objc func previousPixelSize(_ sender: Any?) {
        if let c = options.customPixelSize {
            // from a custom size to the next smaller preset size
            options.pixelSizeIndex = pixelSizes.lastIndex { $0.size < c } ?? (pixelSizes.count - 1)
            options.customPixelSize = nil
        } else {
            options.pixelSizeIndex = (options.pixelSizeIndex - 1 + pixelSizes.count) % pixelSizes.count
        }
        updateRenderParams()
        updateTitle()
    }

    @objc func toggleDPIScaling(_ sender: Any?) {
        options.dpiScaling.toggle()
        updateRenderParams()
    }

    @objc func customPixelSizeMenu(_ sender: Any?) { customPixelSizeDialog() }

    @objc func selectPixelSize(_ sender: NSMenuItem) {
        options.customPixelSize = nil
        options.pixelSizeIndex = sender.tag
        updateRenderParams()
        updateTitle()
    }

    @objc func cropMenu(_ sender: Any?) { cropDialog() }

    @objc func toggleCaptureCursor(_ sender: Any?) {
        options.captureCursor.toggle()
        if running { start() }
    }

    // MARK: - Output actions

    @objc func selectGlass(_ sender: Any?) {
        guard options.clone else { return }
        options.clone = false
        options.lockedArea = nil
        if running { start() } else { updateWindowMode() }
    }

    @objc func selectClone(_ sender: Any?) {
        guard !options.clone else { return }
        options.clone = true
        if running { start() } else { updateWindowMode() }
    }

    @objc func selectSolid(_ sender: Any?) {
        options.transparent = false
        updateWindowMode()
    }

    @objc func selectClickThrough(_ sender: Any?) {
        options.transparent = true
        updateWindowMode()
    }

    @objc func toggleFlipH(_ sender: Any?) {
        options.flipHorizontal.toggle()
        updateRenderParams()
    }

    @objc func toggleFlipV(_ sender: Any?) {
        options.flipVertical.toggle()
        updateRenderParams()
    }

    @objc func selectFreeScale(_ sender: Any?) {
        options.freeScale = true
        updateRenderParams()
        updateTitle()
    }

    @objc func selectOutputScale(_ sender: NSMenuItem) {
        options.freeScale = false
        options.outputScaleIndex = sender.tag
        lastFrameSize = .zero
        updateRenderParams()
        updateTitle()
    }

    @objc func toggleRetainScale(_ sender: Any?) {
        scaleRetained.toggle()
        updateWindowMode()
    }

    @objc func selectAspectRatio(_ sender: NSMenuItem) {
        if sender.tag == customAspectIndex {
            customAspectDialog()
        } else {
            options.aspectRatioIndex = sender.tag
            updateRenderParams()
        }
        lastFrameSize = .zero
        updateTitle()
    }

    @objc func selectHorizontal(_ sender: Any?) {
        options.vertical = false
        updateRenderParams()
    }

    @objc func selectVertical(_ sender: Any?) {
        options.vertical = true
        updateRenderParams()
    }

    @objc func fullscreenMenu(_ sender: Any?) { toggleFullscreen() }
    @objc func snapshotMenu(_ sender: Any?) { takeSnapshot(autoSave: false) }

    // MARK: - Shader actions

    @objc func chooseFromLibrary(_ sender: Any?) { showBrowser() }
    @objc func nextShader(_ sender: Any?) { nextPreset(random: false) }
    @objc func randomShader(_ sender: Any?) { nextPreset(random: true) }

    @objc func toggleActive(_ sender: Any?) {
        options.shaderActive.toggle()
        updateRenderParams()
        updateTitle()
    }

    @objc func importMenu(_ sender: Any?) { importCustom() }

    @objc func openRecentImport(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        importCustom(URL(fileURLWithPath: path)) // removed from the list if it can no longer be loaded
    }

    @objc func parametersMenu(_ sender: Any?) { showParameters() }

    // MARK: - Help

    @objc func openProject(_ sender: Any?) { NSWorkspace.shared.open(projectURL) }

    @objc func openManual(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/lumen-tools/MacGlass#readme")!)
    }
}
