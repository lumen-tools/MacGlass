// MacGlass - headless self-test (run by CI): library scan, path resolution, librashader, Bilinear Filter.
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import LibraBridge
import Metal

enum SelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ message: String) {
        print((ok ? "PASS " : "FAIL ") + message)
        if !ok { failures += 1 }
    }

    private static func note(_ message: String) {
        print("     " + message)
    }

    static func run(outDir: URL) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        print("MacGlass \(appVersion) self-test")

        // librashader
        var libPath = ProcessInfo.processInfo.environment["MACGLASS_LIBRASHADER"] ?? ""
        if libPath.isEmpty, let fw = Bundle.main.privateFrameworksPath { libPath = fw + "/librashader.dylib" }
        let loadError = MGLibrashader.loadLibrary(path: libPath)
        check(loadError == nil, "load librashader (\(libPath))" + (loadError.map { ": \($0)" } ?? ""))
        if loadError == nil {
            note("librashader ABI \(MGLibrashader.abiVersion()), API \(MGLibrashader.apiVersion())")
        }

        // Libraries
        let customRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacGlass-selftest-custom-\(getpid())")
        let library = ShaderLibrary(customRoot: customRoot)
        library.rescan()
        for folder in library.root.folders {
            note("library \(folder.name): \(folder.allPresets().count) presets")
        }
        let raCount = library.root.folders.first { $0.name == ShaderLibrary.retroArchName }?.allPresets().count ?? 0
        let rcCount = library.root.folders.first { $0.name == ShaderLibrary.retroCrisisName }?.allPresets().count ?? 0
        check(raCount > 100, "RetroArch library has presets (\(raCount))")
        check(rcCount > 0, "Retro_Crisis library has presets (\(rcCount))")
        check(library.root.folders.map(\.name) == ["RetroArch", "Retro_Crisis", "Custom_Shader"], "browser shows the three libraries")

        // Path resolution: a custom preset pointing at RetroArch's shader folder.
        let custom = customRoot.appendingPathComponent("test")
        try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let customPreset = custom.appendingPathComponent("shaders_slang-reference.slangp")
        try? """
        #reference "../../../RetroArch/shaders/shaders_slang/crt/crt-geom.slangp"
        CRTgamma = "2.2"
        """.write(to: customPreset, atomically: true, encoding: .utf8)
        let customPasses = custom.appendingPathComponent("shaders_slang-paths.slangp")
        try? """
        shaders = 1
        shader0 = "C:\\RetroArch\\shaders\\shaders_slang\\crt\\shaders\\crt-geom.slang"
        filter_linear0 = false
        """.write(to: customPasses, atomically: true, encoding: .utf8)
        library.rescan()
        var customEntries: [PresetEntry] = []
        for url in [customPreset, customPasses] {
            do {
                let resolved = try library.loadablePath(for: url)
                check(resolved != url, "resolve shaders_slang paths in \(url.lastPathComponent)")
                customEntries.append(library.preset(forFile: url))
            } catch {
                check(false, "resolve \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Parameters without a filter chain (also for presets where get_runtime_params fails).
        if loadError == nil {
            for key in ["RetroArch/crt/crt-geom.slangp", "RetroArch/crt/crt-geom-deluxe.slangp"] {
                guard let p = library.preset(forKey: key) else { check(false, "\(key) exists"); continue }
                var err: NSString? = nil
                let path = (try? library.loadablePath(for: p.url)) ?? p.url
                let params = MGFilterChain.parameters(presetPath: path.path, error: &err)
                check(params != nil, "read parameters of \(p.name): \(params?.count ?? 0)" + ((err as String?).map { " (\($0))" } ?? ""))
            }
        }

        // Metal
        guard let device = MTLCreateSystemDefaultDevice() else {
            note("No Metal device on this machine - skipping render tests.")
            return finish()
        }
        note("Metal device: \(device.name)")
        guard let renderer = try? Renderer(device: device) else {
            check(false, "create renderer")
            return finish()
        }
        check(true, "create renderer (built-in Metal shaders compile)")

        bilinearTest(renderer: renderer, device: device)

        guard loadError == nil else { return finish() }
        let pattern = testPattern(device: device, width: 640, height: 480)
        var required: [PresetEntry] = ["RetroArch/crt/crt-geom.slangp", "RetroArch/crt/newpixie-crt.slangp",
                                       "RetroArch/crt/crt-geom-deluxe.slangp", "RetroArch/crt/crt-guest-advanced.slangp"]
            .compactMap { library.preset(forKey: $0) }
        let rc = library.root.folders.first { $0.name == ShaderLibrary.retroCrisisName }?.allPresets() ?? []
        required += rc.prefix(2)
        required += customEntries
        for p in required {
            renderPreset(p, library: library, renderer: renderer, input: pattern, outDir: outDir, required: true)
        }
        // A random sample of further presets (informational; some presets are known to be broken in librashader).
        var sample = library.allPresets.filter { !$0.key.contains("/bezel/") }.shuffled().prefix(8)
        sample.append(contentsOf: rc.dropFirst(2).shuffled().prefix(2))
        for p in sample {
            renderPreset(p, library: library, renderer: renderer, input: pattern, outDir: outDir, required: false)
        }
        try? FileManager.default.removeItem(at: customRoot)
        return finish()
    }

    private static func finish() -> Int32 {
        print(failures == 0 ? "Self-test passed." : "Self-test FAILED (\(failures)).")
        return failures == 0 ? 0 : 1
    }

    private static func renderPreset(_ p: PresetEntry, library: ShaderLibrary, renderer: Renderer, input: MTLTexture,
                                     outDir: URL, required: Bool) {
        let start = Date()
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<[MGShaderParameter], Error> = .failure(ShaderLibraryError.message("timeout"))
        do {
            let path = try library.loadablePath(for: p.url)
            renderer.loadPreset(at: path, values: [:]) { r in
                outcome = r
                sem.signal()
            }
            if sem.wait(timeout: .now() + 300) == .timedOut { outcome = .failure(ShaderLibraryError.message("timeout")) }
        } catch {
            outcome = .failure(error)
        }
        let label = "\(required ? "" : "(sample) ")\(p.key)"
        switch outcome {
        case .failure(let e):
            if required { check(false, "load \(label): \(e.localizedDescription)") } else { note("could not load \(label): \(e.localizedDescription)") }
            return
        case .success(let params):
            var rp = RenderParams()
            rp.inputScale = 2
            rp.freeScale = true
            let (image, error) = renderer.renderOffscreen(input: input, params: rp, outputW: 1280, outputH: 960)
            let secs = String(format: "%.1fs", Date().timeIntervalSince(start))
            if let image {
                let name = p.key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_") + ".png"
                if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: outDir.appendingPathComponent(name))
                }
                let ok = !isBlack(image)
                if required { check(ok, "render \(label) (\(params.count) parameters, \(secs))") } else {
                    note("\(ok ? "rendered" : "black output from") \(label) (\(params.count) parameters, \(secs))")
                }
            } else if required {
                check(false, "render \(label): \(error ?? "no image")")
            } else {
                note("could not render \(label): \(error ?? "no image")")
            }
        }
    }

    /// Bilinear Filter: a 1-pixel checkerboard at Pixel Size x2 must average to grey (footprint), while
    /// point sampling keeps pure black/white.
    private static func bilinearTest(renderer: Renderer, device: MTLDevice) {
        let size = 64
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let tex = device.makeTexture(descriptor: d) else { check(false, "bilinear test texture"); return }
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size where (x + y) % 2 == 1 {
                let i = (y * size + x) * 4
                bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 0
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bytes, bytesPerRow: size * 4)

        renderer.unloadPreset()
        for bilinear in [false, true] {
            var p = RenderParams()
            p.inputScale = 2
            p.bilinear = bilinear
            let (image, error) = renderer.renderOffscreen(input: tex, params: p, outputW: size, outputH: size)
            guard let image, let px = pixels(image) else {
                check(false, "bilinear \(bilinear ? "on" : "off"): \(error ?? "no image")")
                continue
            }
            let greens = stride(from: 1, to: px.count, by: 4).map { Int(px[$0]) }
            let minV = greens.min() ?? 0, maxV = greens.max() ?? 0
            if bilinear {
                check(minV >= 120 && maxV <= 135, "Bilinear Filter averages the source footprint (values \(minV)...\(maxV), expected ~128)")
            } else {
                check(minV == 0 || maxV == 255, "point sampling without Bilinear Filter (values \(minV)...\(maxV))")
                check(Set(greens).isSubset(of: [0, 255]), "point sampling keeps pure black/white")
            }
        }
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }

    private static func isBlack(_ image: CGImage) -> Bool {
        guard let px = pixels(image) else { return true }
        var sum = 0
        for i in stride(from: 0, to: px.count, by: 4) { sum += Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) }
        return sum < px.count / 4 // average below ~1/3 of a step per channel
    }

    /// Colour bars with a gradient, as a stand-in for a game picture.
    private static func testPattern(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        let tex = device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let bars: [(UInt8, UInt8, UInt8)] = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
                                              (255, 0, 255), (255, 0, 0), (0, 0, 255), (40, 40, 40)]
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let c = bars[x * bars.count / width]
                let f = y < height * 3 / 4 ? 1.0 : Double(x) / Double(width)
                bytes[i] = UInt8(Double(c.2) * f)
                bytes[i + 1] = UInt8(Double(c.1) * f)
                bytes[i + 2] = UInt8(Double(c.0) * f)
                bytes[i + 3] = 255
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return tex
    }
}
