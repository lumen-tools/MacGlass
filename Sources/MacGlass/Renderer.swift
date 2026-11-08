// MacGlass - Metal renderer: preprocess (crop + Pixel Size + Bilinear Filter), librashader chain, output.
// SPDX-License-Identifier: GPL-3.0-only
// Portions derived from ShaderGlass (https://github.com/mausimus/ShaderGlass), Copyright (C) 2021-2025 mausimus, GPL-3.0.
// MacGlass is an independent, unofficial project and is not affiliated with ShaderGlass.
import AppKit
import CoreVideo
import LibraBridge
import Metal
import QuartzCore

/// A captured frame. Keeps the backing buffers alive while the texture is in use.
final class CaptureFrame {
    let texture: MTLTexture
    let keepAlive: [Any]
    let serial: UInt64

    init(texture: MTLTexture, keepAlive: [Any], serial: UInt64) {
        self.texture = texture
        self.keepAlive = keepAlive
        self.serial = serial
    }
}

/// Processing settings, written by the main thread and read by the render thread.
struct RenderParams {
    /// Captured pixels per shader-input pixel (Pixel Size x DPI scale).
    var inputScale: Float = 3
    /// ShaderGlass output scale factors (captured pixels per output pixel); (0, 0) = Stretch.
    var outputScaleW: Float = 1
    var outputScaleH: Float = 1
    var freeScale = false
    var crop = CropInsets()
    var vertical = false
    var flipH = false
    var flipV = false
    var bilinear = false
    var shaderActive = true
    var frameSkip = 0
    var paused = false
    /// Desktop Glass: top-left of the captured area in texture pixels. nil = fit the whole (cropped) input.
    var glassOrigin: CGPoint? = nil
    /// Part of the input to use (texture pixels, top-left origin), e.g. a locked desktop area in Clone mode.
    var sourceRegion: CGRect? = nil
}

/// The geometry of one frame (ShaderGlass::Process).
struct FrameGeometry: Equatable {
    var srcRect: CGRect        // in texture pixels
    var originalW: Int
    var originalH: Int
    var viewport: CGRect       // in drawable pixels
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let renderQueue = DispatchQueue(label: "MacGlass.render", qos: .userInteractive)

    private let preprocessPipeline: MTLRenderPipelineState
    private let footprintPipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState

    weak var layer: CAMetalLayer?

    // Shared state (guarded by `lock`).
    private let lock = NSLock()
    private var params = RenderParams()
    private var latestFrame: CaptureFrame?
    private var chain: MGFilterChain?
    private var snapshotRequest: ((CGImage?) -> Void)?

    // Render-thread state.
    private var originalTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var frameCount: UInt = 0
    private var startTime = CACurrentMediaTime()
    private var lastLogicalFrame = -1
    private var lastInputSerial: UInt64 = 0
    private var lastRenderTime = CACurrentMediaTime()
    private var busy = false // touched only under `lock`
    private var pending = false // a tick arrived while rendering (under `lock`)
    private var lastInputTime = CACurrentMediaTime() // under `lock`
    private var lastGeometry: FrameGeometry?
    private var lastDrawableSize = CGSize.zero

    // Statistics.
    private(set) var renderedFrames = 0
    private(set) var inputFrames = 0
    var onChainError: ((String) -> Void)?

    init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw ShaderLibraryError.message("Could not create a Metal command queue.") }
        queue = q
        let library = try device.makeLibrary(source: builtinMetalSource, options: nil)

        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "quad_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        }
        preprocessPipeline = try pipeline("copy_fragment")
        footprintPipeline = try pipeline("footprint_fragment")
        presentPipeline = try pipeline("copy_fragment")

        func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter
            d.magFilter = filter
            d.mipFilter = .notMipmapped
            d.sAddressMode = .clampToEdge
            d.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: d)!
        }
        nearestSampler = sampler(.nearest)
        linearSampler = sampler(.linear)
    }

    // MARK: - Main-thread API

    func update(_ change: (inout RenderParams) -> Void) {
        lock.lock()
        change(&params)
        lock.unlock()
    }

    var currentParams: RenderParams {
        lock.lock()
        defer { lock.unlock() }
        return params
    }

    func submit(frame: CaptureFrame?) {
        lock.lock()
        latestFrame = frame
        if frame != nil {
            inputFrames += 1
            lastInputTime = CACurrentMediaTime()
        }
        lock.unlock()
        // Render a new capture right away instead of waiting for the next display refresh (lower latency).
        if frame != nil { tick() }
    }

    func takeStatistics() -> (input: Int, output: Int) {
        lock.lock()
        defer { lock.unlock() }
        let r = (inputFrames, renderedFrames)
        inputFrames = 0
        renderedFrames = 0
        return r
    }

    /// Loads a preset on the render queue (the Metal runtime of librashader is not thread-safe).
    func loadPreset(at url: URL, values: [String: Float],
                    completion: @escaping (Result<[MGShaderParameter], Error>) -> Void) {
        renderQueue.async { [self] in
            var params: NSArray? = nil
            var error: NSString? = nil
            let newChain = MGFilterChain.make(presetPath: url.path, queue: queue, parameters: &params, error: &error)
            guard let newChain else {
                let message = (error as String?) ?? "Unknown error"
                DispatchQueue.main.async { completion(.failure(ShaderLibraryError.message(message))) }
                return
            }
            for (name, value) in values { newChain.setParameter(name, value: value) }
            lock.lock()
            let old = chain
            chain = newChain
            lock.unlock()
            _ = old // released here, on the render queue
            frameCount = 0
            startTime = CACurrentMediaTime()
            lastLogicalFrame = -1
            let list = (params as? [MGShaderParameter]) ?? []
            DispatchQueue.main.async { completion(.success(list)) }
        }
    }

    func unloadPreset() {
        renderQueue.async { [self] in
            lock.lock()
            let old = chain
            chain = nil
            lock.unlock()
            _ = old
        }
    }

    /// Thread-safe (libra_mtl_filter_chain_set_param).
    func setParameter(_ name: String, value: Float) {
        lock.lock()
        chain?.setParameter(name, value: value)
        lock.unlock()
    }

    func requestSnapshot(_ completion: @escaping (CGImage?) -> Void) {
        lock.lock()
        snapshotRequest = completion
        lock.unlock()
    }

    /// Called from the display link thread.
    /// Called for every new capture frame and from the display link.
    func tick() {
        lock.lock()
        if busy {
            pending = true // render again right after the current frame, so no new capture is skipped
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        renderQueue.async { [self] in
            while true {
                autoreleasepool { renderFrame() }
                lock.lock()
                if pending {
                    pending = false
                    lock.unlock()
                    continue
                }
                busy = false
                lock.unlock()
                break
            }
        }
    }

    // MARK: - Geometry (ShaderGlass::Process)

    static func geometry(textureW: Int, textureH: Int, drawableW: Int, drawableH: Int, p: RenderParams) -> FrameGeometry? {
        guard textureW > 0, textureH > 0, drawableW > 0, drawableH > 0 else { return nil }
        let osW = p.outputScaleW, osH = p.outputScaleH
        var clientW = Float(drawableW), clientH = Float(drawableH)
        var boxX: Float = 0, boxY: Float = 0
        var src: CGRect

        if let origin = p.glassOrigin {
            // Desktop Glass: the window shows the area of the desktop underneath it.
            let destW = clientW * (osW == 0 ? 1 : osW)
            let destH = clientH * (osH == 0 ? 1 : osH)
            if destW <= p.inputScale || destH <= p.inputScale { return nil }
            src = CGRect(x: origin.x, y: origin.y, width: CGFloat(destW), height: CGFloat(destH))
            let ow = Int(destW / p.inputScale), oh = Int(destH / p.inputScale)
            guard ow > 0, oh > 0 else { return nil }
            return FrameGeometry(srcRect: src, originalW: ow, originalH: oh,
                                 viewport: CGRect(x: 0, y: 0, width: drawableW, height: drawableH))
        }

        if let region = p.sourceRegion {
            src = region.intersection(CGRect(x: 0, y: 0, width: textureW, height: textureH))
            if src.isEmpty { src = CGRect(x: 0, y: 0, width: textureW, height: textureH) }
        } else {
            let c = p.crop
            src = CGRect(x: c.left, y: c.top,
                         width: max(1, textureW - c.left - c.right), height: max(1, textureH - c.top - c.bottom))
        }
        let captureW = Float(src.width), captureH = Float(src.height)
        if !p.freeScale && osW != 0 && osH != 0 {
            clientW = (captureW / osW).rounded()
            clientH = (captureH / osH).rounded()
        }
        if captureW != 0 && captureH != 0 && osW != 0 && osH != 0 {
            let inputAR = captureW / captureH
            let outputAR = (clientW * osW) / (clientH * osH)
            if outputAR > inputAR {
                let newW = (clientH * (osH / osW) * inputAR).rounded()
                boxX = (clientW - newW) / 2
                clientW = newW
            } else if outputAR < inputAR {
                let newH = (clientW * (osW / osH) / inputAR).rounded()
                boxY = (clientH - newH) / 2
                clientH = newH
            }
            if !p.freeScale {
                boxX += (Float(drawableW) - captureW / osW) / 2
                boxY += (Float(drawableH) - captureH / osH) / 2
            }
            boxX = max(0, boxX)
            boxY = max(0, boxY)
        }
        let destW = clientW * (osW == 0 ? 1 : osW)
        let destH = clientH * (osH == 0 ? 1 : osH)
        if destW <= p.inputScale || destH <= p.inputScale { return nil }
        let ow = Int(captureW / p.inputScale), oh = Int(captureH / p.inputScale)
        guard ow > 0, oh > 0, clientW >= 1, clientH >= 1 else { return nil }
        return FrameGeometry(srcRect: src, originalW: ow, originalH: oh,
                             viewport: CGRect(x: CGFloat(Int(boxX)), y: CGFloat(Int(boxY)),
                                              width: CGFloat(Int(clientW)), height: CGFloat(Int(clientH))))
    }

    // MARK: - Rendering (render queue)

    private func makeTexture(_ w: Int, _ h: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: max(1, w), height: max(1, h), mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func encodeQuad(_ cb: MTLCommandBuffer, target: MTLTexture, viewport: CGRect?, clear: Bool,
                            pipeline: MTLRenderPipelineState, source: MTLTexture, sampler: MTLSamplerState,
                            srcRect: SIMD4<Float>, transpose: Bool, flipH: Bool, flipV: Bool) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        if let v = viewport {
            enc.setViewport(MTLViewport(originX: Double(v.minX), originY: Double(v.minY),
                                        width: Double(v.width), height: Double(v.height), znear: 0, zfar: 1))
        }
        var u = QuadUniforms(srcRect: srcRect, transpose: transpose ? 1 : 0, flipH: flipH ? 1 : 0, flipV: flipV ? 1 : 0, pad: 0)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func renderFrame() {
        lock.lock()
        let p = params
        let frame = latestFrame
        let currentChain = chain
        let snapshot = snapshotRequest
        snapshotRequest = nil
        lock.unlock()

        guard let layer, let frame else { snapshot?(nil); return }
        if p.paused && snapshot == nil { return }

        // Pacing: every new capture frame is rendered at once. Without new input (static picture), the
        // display link keeps animated shaders running at the display refresh rate.
        // FPS menu (frame skip): as ShaderGlass, render every n-th logical frame of 60 fps.
        let now = CACurrentMediaTime()
        let logical = Int((now - startTime) * 60.0)
        lock.lock()
        let sinceInput = now - lastInputTime
        lock.unlock()
        if snapshot == nil {
            if p.frameSkip > 0 {
                if logical == lastLogicalFrame { return }
                if logical % (p.frameSkip + 1) != 0 { return }
            } else {
                let newInput = frame.serial != lastInputSerial
                let idleAnimation = sinceInput > 0.025 && now - lastRenderTime > 0.006
                if !newInput && !idleAnimation { return }
            }
        }
        lastLogicalFrame = logical
        lastInputSerial = frame.serial

        let drawableSize = layer.drawableSize
        let dw = Int(drawableSize.width), dh = Int(drawableSize.height)
        let texW = frame.texture.width, texH = frame.texture.height
        guard let g = Renderer.geometry(textureW: texW, textureH: texH, drawableW: dw, drawableH: dh, p: p) else {
            snapshot?(nil)
            return
        }

        // Shader input ("Original") and chain output; swapped for Vertical orientation.
        let ow = p.vertical ? g.originalH : g.originalW
        let oh = p.vertical ? g.originalW : g.originalH
        let vw = Int(g.viewport.width), vh = Int(g.viewport.height)
        let cw = p.vertical ? vh : vw
        let ch = p.vertical ? vw : vh
        if originalTexture?.width != ow || originalTexture?.height != oh {
            originalTexture = makeTexture(ow, oh)
        }
        if outputTexture?.width != cw || outputTexture?.height != ch {
            outputTexture = makeTexture(cw, ch)
        }
        guard let original = originalTexture, let output = outputTexture else { return }

        let src = SIMD4<Float>(Float(g.srcRect.minX) / Float(texW), Float(g.srcRect.minY) / Float(texH),
                               Float(g.srcRect.maxX) / Float(texW), Float(g.srcRect.maxY) / Float(texH))

        // 1. Preprocess: captured image -> shader input (Pixel Size). Point sampling, or the
        //    footprint average with bilinear taps when "Bilinear Filter" is on.
        guard let cb1 = queue.makeCommandBuffer() else { return }
        encodeQuad(cb1, target: original, viewport: nil, clear: false,
                   pipeline: p.bilinear ? footprintPipeline : preprocessPipeline, source: frame.texture,
                   sampler: p.bilinear ? linearSampler : nearestSampler, srcRect: src,
                   transpose: p.vertical, flipH: false, flipV: false)
        cb1.addCompletedHandler { _ in _ = frame } // keep the capture buffer alive
        cb1.commit()

        // 2. Shader chain (its command buffer must not contain earlier commands).
        guard let cb2 = queue.makeCommandBuffer() else { return }
        var chainSource = original
        if p.shaderActive, let currentChain {
            var error: NSString? = nil
            let delta = UInt32(max(0, min(1000, (now - lastRenderTime) * 1000)))
            if currentChain.render(commandBuffer: cb2, frameCount: frameCount, input: original, output: output,
                                   framesPerSec: 60, frameTimeDelta: delta, error: &error) {
                chainSource = output
            } else if let e = error as String? {
                let handler = onChainError
                DispatchQueue.main.async { handler?(e) }
            }
            // FrameCount advances at 60 per second whatever the render rate (as ShaderGlass' logical frames),
            // so animated shaders keep their speed on 120 Hz displays.
            frameCount = UInt(max(0, logical))
        }
        lastRenderTime = now

        // 3. Output: chain result into the window (letterboxing, flip, rotate back).
        let unit = SIMD4<Float>(0, 0, 1, 1)
        if let drawable = layer.nextDrawable() {
            encodeQuad(cb2, target: drawable.texture, viewport: g.viewport, clear: true,
                       pipeline: presentPipeline, source: chainSource, sampler: nearestSampler, srcRect: unit,
                       transpose: p.vertical, flipH: p.flipH, flipV: p.flipV)
            cb2.present(drawable)
        }

        var snapshotTexture: MTLTexture?
        var snapshotBuffer: MTLBuffer?
        if snapshot != nil, vw > 0, vh > 0, let t = makeTexture(vw, vh),
           let buffer = device.makeBuffer(length: vw * vh * 4, options: .storageModeShared) {
            encodeQuad(cb2, target: t, viewport: nil, clear: true, pipeline: presentPipeline, source: chainSource,
                       sampler: nearestSampler, srcRect: unit, transpose: p.vertical, flipH: p.flipH, flipV: p.flipV)
            if let blit = cb2.makeBlitCommandEncoder() {
                blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: vw, height: vh, depth: 1), to: buffer, destinationOffset: 0,
                          destinationBytesPerRow: vw * 4, destinationBytesPerImage: vw * vh * 4)
                blit.endEncoding()
            }
            snapshotTexture = t
            snapshotBuffer = buffer
        }
        cb2.commit()

        if let snapshot {
            cb2.waitUntilCompleted()
            _ = snapshotTexture
            var image: CGImage?
            if let buffer = snapshotBuffer {
                image = Renderer.makeImage(buffer: buffer, width: vw, height: vh)
            }
            DispatchQueue.main.async { snapshot(image) }
        }

        lock.lock()
        renderedFrames += 1
        lock.unlock()
    }

    static func makeImage(buffer: MTLBuffer, width: Int, height: Int) -> CGImage? {
        let data = Data(bytes: buffer.contents(), count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Offscreen rendering (self-test)

    /// Renders one frame through the chain into a new texture (used by the self-test).
    func renderOffscreen(input: MTLTexture, params p: RenderParams, outputW: Int, outputH: Int) -> (CGImage?, String?) {
        var result: (CGImage?, String?) = (nil, nil)
        renderQueue.sync {
            guard let g = Renderer.geometry(textureW: input.width, textureH: input.height, drawableW: outputW, drawableH: outputH, p: p),
                  let original = makeTexture(g.originalW, g.originalH),
                  let output = makeTexture(Int(g.viewport.width), Int(g.viewport.height)),
                  let buffer = device.makeBuffer(length: outputW * outputH * 4, options: .storageModeShared),
                  let target = makeTexture(outputW, outputH),
                  let cb1 = queue.makeCommandBuffer(), let cb2 = queue.makeCommandBuffer() else {
                result = (nil, "Could not set up offscreen rendering.")
                return
            }
            let src = SIMD4<Float>(Float(g.srcRect.minX) / Float(input.width), Float(g.srcRect.minY) / Float(input.height),
                                   Float(g.srcRect.maxX) / Float(input.width), Float(g.srcRect.maxY) / Float(input.height))
            encodeQuad(cb1, target: original, viewport: nil, clear: false,
                       pipeline: p.bilinear ? footprintPipeline : preprocessPipeline, source: input,
                       sampler: p.bilinear ? linearSampler : nearestSampler, srcRect: src,
                       transpose: false, flipH: false, flipV: false)
            cb1.commit()
            lock.lock()
            let c = chain
            lock.unlock()
            var source = original
            if let c {
                var error: NSString? = nil
                for i in 0..<3 { // a few frames, so history/feedback passes run too
                    guard let cbc = queue.makeCommandBuffer() else { break }
                    if !c.render(commandBuffer: cbc, frameCount: UInt(i), input: original, output: output, framesPerSec: 60,
                                 frameTimeDelta: 16, error: &error) {
                        result = (nil, (error as String?) ?? "Frame failed")
                        cbc.commit()
                        return
                    }
                    cbc.commit()
                }
                source = output
            }
            encodeQuad(cb2, target: target, viewport: g.viewport, clear: true, pipeline: presentPipeline, source: source,
                       sampler: nearestSampler, srcRect: SIMD4<Float>(0, 0, 1, 1), transpose: false, flipH: false, flipV: false)
            if let blit = cb2.makeBlitCommandEncoder() {
                blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: outputW, height: outputH, depth: 1), to: buffer, destinationOffset: 0,
                          destinationBytesPerRow: outputW * 4, destinationBytesPerImage: outputW * outputH * 4)
                blit.endEncoding()
            }
            cb2.commit()
            cb2.waitUntilCompleted()
            if let e = cb2.error { result = (nil, e.localizedDescription); return }
            result = (Renderer.makeImage(buffer: buffer, width: outputW, height: outputH), nil)
        }
        return result
    }
}

struct QuadUniforms {
    var srcRect: SIMD4<Float>
    var transpose: UInt32
    var flipH: UInt32
    var flipV: UInt32
    var pad: UInt32
}
