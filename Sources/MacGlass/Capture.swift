// MacGlass - input capture: ScreenCaptureKit (display / window), capture devices, image files.
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import MetalKit
import ScreenCaptureKit

/// Turns pixel buffers into Metal textures and hands them to the renderer.
final class FrameSink {
    let device: MTLDevice
    weak var renderer: Renderer?
    private var cache: CVMetalTextureCache?
    private var serial: UInt64 = 0
    private let lock = NSLock()
    /// Size of the last frame (pixels).
    private(set) var lastSize = CGSize.zero

    init(device: MTLDevice, renderer: Renderer) {
        self.device = device
        self.renderer = renderer
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    func push(_ pixelBuffer: CVPixelBuffer) {
        guard let cache else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return }
        lock.lock()
        serial += 1
        let s = serial
        lastSize = CGSize(width: w, height: h)
        lock.unlock()
        renderer?.submit(frame: CaptureFrame(texture: texture, keepAlive: [cvTexture, pixelBuffer], serial: s))
    }

    func push(texture: MTLTexture) {
        lock.lock()
        serial += 1
        let s = serial
        lastSize = CGSize(width: texture.width, height: texture.height)
        lock.unlock()
        renderer?.submit(frame: CaptureFrame(texture: texture, keepAlive: [], serial: s))
    }

    var frameSize: CGSize {
        lock.lock()
        defer { lock.unlock() }
        return lastSize
    }

    func flush() {
        CVMetalTextureCacheFlush(cache!, 0)
        renderer?.submit(frame: nil)
        lock.lock()
        lastSize = .zero
        lock.unlock()
    }
}

enum CaptureError: LocalizedError {
    case notFound(String)
    case permission(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let what): return "\(what) is not available for capture."
        case .permission:
            return "MacGlass needs permission to record the screen.\n\nAllow MacGlass in System Settings > Privacy & Security > Screen & System Audio Recording, then restart MacGlass."
        }
    }
}

/// Screen and window capture with ScreenCaptureKit.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sink: FrameSink
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private let sampleQueue = DispatchQueue(label: "MacGlass.capture", qos: .userInteractive)
    var onStop: ((Error?) -> Void)?

    init(sink: FrameSink) {
        self.sink = sink
    }

    var isRunning: Bool { stream != nil }

    static func backingScale(forDisplay id: CGDirectDisplayID) -> CGFloat {
        for s in NSScreen.screens where s.displayID == id { return s.backingScaleFactor }
        if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
            return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        }
        return 1
    }

    private static func makeConfiguration(width: Int, height: Int, showsCursor: Bool, maxRate: Bool) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = max(1, width)
        c.height = max(1, height)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = showsCursor
        c.queueDepth = 5
        c.minimumFrameInterval = maxRate ? CMTime(value: 1, timescale: 240) : CMTime(value: 1, timescale: 60)
        c.capturesAudio = false
        return c
    }

    /// Captures a whole display, without MacGlass' own windows (no mirror feedback in Glass mode).
    func startDisplay(_ displayID: CGDirectDisplayID, showsCursor: Bool, maxRate: Bool) async throws {
        await stop()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permission(error.localizedDescription)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.notFound("The display")
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let scale = ScreenCapture.backingScale(forDisplay: display.displayID)
        let config = ScreenCapture.makeConfiguration(width: Int(CGFloat(display.width) * scale),
                                                     height: Int(CGFloat(display.height) * scale),
                                                     showsCursor: showsCursor, maxRate: maxRate)
        try await start(filter: filter, configuration: config)
    }

    /// Captures a single window (only that window's content is recorded).
    func startWindow(_ windowID: CGWindowID, showsCursor: Bool, maxRate: Bool) async throws {
        await stop()
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.permission(error.localizedDescription)
        }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.notFound("The window")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = WindowList.backingScale(for: window.frame)
        let config = ScreenCapture.makeConfiguration(width: Int(window.frame.width * scale),
                                                     height: Int(window.frame.height * scale),
                                                     showsCursor: showsCursor, maxRate: maxRate)
        try await start(filter: filter, configuration: config)
    }

    /// Follows a resized window.
    func updateSize(width: Int, height: Int) {
        guard let stream, let configuration, configuration.width != width || configuration.height != height else { return }
        configuration.width = max(1, width)
        configuration.height = max(1, height)
        stream.updateConfiguration(configuration) { error in
            if let error { NSLog("MacGlass: updateConfiguration failed: \(error)") }
        }
    }

    private func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let s = SCStream(filter: filter, configuration: configuration, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await s.startCapture()
        stream = s
        self.configuration = configuration
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        configuration = nil
        try? await s.stopCapture()
        sink.flush()
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        sink.push(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.configuration = nil
            self.onStop?(error)
        }
    }
}

/// Video capture devices (Input > Device).
final class DeviceCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let sink: FrameSink
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "MacGlass.device", qos: .userInteractive)

    init(sink: FrameSink) {
        self.sink = sink
    }

    static func devices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types += [.external, .continuityCamera]
        } else {
            types.append(.externalUnknown)
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    func start(uniqueID: String) throws {
        stop()
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else { throw CaptureError.notFound("The capture device") }
        let s = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard s.canAddInput(input) else { throw CaptureError.notFound("The capture device") }
        s.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(output) else { throw CaptureError.notFound("The capture device") }
        s.addOutput(output)
        session = s
        queue.async { s.startRunning() }
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        queue.async { s.stopRunning() }
        sink.flush()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        sink.push(pb)
    }
}

/// Input > File...
enum ImageInput {
    static func load(_ url: URL, device: MTLDevice) throws -> MTLTexture {
        let loader = MTKTextureLoader(device: device)
        return try loader.newTexture(URL: url, options: [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            .origin: MTKTextureLoader.Origin.topLeft.rawValue,
        ])
    }
}

/// On-screen windows (Input > Window) via the Window Server list.
struct WindowInfo {
    let id: CGWindowID
    let owner: String
    let title: String
    let pid: pid_t
    /// Window Server coordinates (points, top-left origin of the main display).
    let bounds: CGRect

    var menuTitle: String {
        let t = title.isEmpty ? owner : "\(owner) - \(title)"
        return t.count > 60 ? String(t.prefix(57)) + "..." : t
    }
}

enum WindowList {
    static func windows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info(from: $0) }.filter { w in
            w.pid != me && w.bounds.width >= 64 && w.bounds.height >= 64 && !(w.owner == "Window Server" || w.owner == "Dock")
        }
    }

    static func window(_ id: CGWindowID) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] else { return nil }
        return list.compactMap { info(from: $0) }.first { $0.id == id }
    }

    static func isOnScreen(_ id: CGWindowID) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let first = list.first else { return false }
        return (first[kCGWindowIsOnscreen as String] as? Bool) ?? false
    }

    private static func info(from d: [String: Any]) -> WindowInfo? {
        guard let id = d[kCGWindowNumber as String] as? CGWindowID,
              let layer = d[kCGWindowLayer as String] as? Int, layer == 0,
              let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        let owner = d[kCGWindowOwnerName as String] as? String ?? ""
        let title = d[kCGWindowName as String] as? String ?? ""
        let pid = d[kCGWindowOwnerPID as String] as? pid_t ?? 0
        return WindowInfo(id: id, owner: owner, title: title, pid: pid, bounds: bounds)
    }

    /// Converts Window Server coordinates (top-left origin) into Cocoa screen coordinates.
    static func cocoaRect(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func backingScale(for windowServerRect: CGRect) -> CGFloat {
        let r = cocoaRect(windowServerRect)
        let center = CGPoint(x: r.midX, y: r.midY)
        return (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.backingScaleFactor ?? 2
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var displayName: String {
        if #available(macOS 10.15, *) { return localizedName }
        return "Display \(displayID)"
    }
}
