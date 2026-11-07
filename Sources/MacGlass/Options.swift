// MacGlass - option tables (taken from ShaderGlass' Options.h) and the capture options.
// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation

struct PixelSizeInfo {
    let size: Float
    let text: String
    let mnemonic: String
}

struct AspectRatioInfo {
    var ratio: Float
    let text: String
    let mnemonic: String
}

struct FrameSkipInfo {
    let skip: Int
    let text: String
    let mnemonic: String
}

struct OutputScaleInfo {
    let scale: Float
    let text: String
    let mnemonic: String
}

let customMnemonic = "c"

let pixelSizes: [PixelSizeInfo] = [
    .init(size: 1.0, text: "x1", mnemonic: "1"),
    .init(size: 2.0, text: "x2", mnemonic: "2"),
    .init(size: 2.25, text: "x2.25 (480p -> 1080p)", mnemonic: "2.25"),
    .init(size: 3.0, text: "x3", mnemonic: "3"),
    .init(size: 4.0, text: "x4", mnemonic: "4"),
    .init(size: 4.5, text: "x4.5 (240p -> 1080p)", mnemonic: "4.5"),
    .init(size: 5.0, text: "x5", mnemonic: "5"),
    .init(size: 5.4, text: "x5.4 (200p -> 1080p)", mnemonic: "5.4"),
    .init(size: 6.0, text: "x6 (240p -> 1440p)", mnemonic: "6"),
    .init(size: 7.0, text: "x7", mnemonic: "7"),
    .init(size: 7.2, text: "x7.2 (200p -> 1440p)", mnemonic: "7.2"),
    .init(size: 8.0, text: "x8", mnemonic: "8"),
    .init(size: 9.0, text: "x9 (240p -> 4K)", mnemonic: "9"),
    .init(size: 10.0, text: "x10", mnemonic: "10"),
    .init(size: 10.8, text: "x10.8 (200p -> 4K)", mnemonic: "10.8"),
]

var aspectRatios: [AspectRatioInfo] = [
    .init(ratio: 1.0, text: "None", mnemonic: "1"),
    .init(ratio: 1.2, text: "x1.2 (DOS, NTSC)", mnemonic: "1.2"),
    .init(ratio: 0.9375, text: "x0.94 (PAL)", mnemonic: "0.94"),
    .init(ratio: 0.8, text: "x0.8 (NES)", mnemonic: "0.8"),
    .init(ratio: 0.857143, text: "x0.86 (SNES)", mnemonic: "0.86"),
    .init(ratio: 0.5, text: "x0.5 (double wide)", mnemonic: "0.5"),
    .init(ratio: 2.0, text: "x2.0 (double tall)", mnemonic: "2.0"),
    .init(ratio: 1.0, text: "Custom...", mnemonic: customMnemonic),
    .init(ratio: 0.0, text: "Stretch", mnemonic: "0"),
]
let customAspectIndex = 7

let frameSkips: [FrameSkipInfo] = [
    .init(skip: 0, text: "100% (VSync)", mnemonic: "1"),
    .init(skip: 1, text: "1 / 2", mnemonic: "2"),
    .init(skip: 2, text: "1 / 3", mnemonic: "3"),
    .init(skip: 3, text: "1 / 4", mnemonic: "4"),
    .init(skip: 4, text: "1 / 5", mnemonic: "5"),
    .init(skip: 5, text: "1 / 6", mnemonic: "6"),
    .init(skip: 6, text: "1 / 7", mnemonic: "7"),
    .init(skip: 7, text: "1 / 8", mnemonic: "8"),
    .init(skip: 8, text: "1 / 9", mnemonic: "9"),
    .init(skip: 9, text: "1 / 10", mnemonic: "10"),
    .init(skip: 11, text: "1 / 12", mnemonic: "12"),
    .init(skip: 13, text: "1 / 14", mnemonic: "14"),
    .init(skip: 15, text: "1 / 16", mnemonic: "16"),
    .init(skip: 17, text: "1 / 18", mnemonic: "18"),
    .init(skip: 19, text: "1 / 20", mnemonic: "20"),
]

let outputScales: [OutputScaleInfo] = [
    .init(scale: 1.0, text: "100%", mnemonic: "100"),
    .init(scale: 1.5, text: "150%", mnemonic: "150"),
    .init(scale: 2.0, text: "200%", mnemonic: "200"),
    .init(scale: 2.5, text: "250%", mnemonic: "250"),
    .init(scale: 3.0, text: "300%", mnemonic: "300"),
    .init(scale: 3.5, text: "350%", mnemonic: "350"),
    .init(scale: 4.0, text: "400%", mnemonic: "400"),
    .init(scale: 5.0, text: "500%", mnemonic: "500"),
    .init(scale: 6.0, text: "600%", mnemonic: "600"),
    .init(scale: 7.0, text: "700%", mnemonic: "700"),
    .init(scale: 8.0, text: "800%", mnemonic: "800"),
    .init(scale: 9.0, text: "900%", mnemonic: "900"),
    .init(scale: 10.0, text: "1000%", mnemonic: "1000"),
    .init(scale: 0.75, text: "75%", mnemonic: "75"),
    .init(scale: 0.5, text: "50%", mnemonic: "50"),
    .init(scale: 0.25, text: "25%", mnemonic: "25"),
]

/// What is captured.
enum InputKind: Equatable {
    case none
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case device(String)   // AVCaptureDevice uniqueID
    case file(URL)
}

/// Crop insets in captured pixels.
struct CropInsets: Equatable, Codable {
    var left = 0
    var top = 0
    var right = 0
    var bottom = 0
    var isZero: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
}

/// Everything that controls processing (the counterpart of ShaderGlass' CaptureOptions).
struct CaptureOptions {
    var input: InputKind = .none
    var pixelSizeIndex = 3
    var dpiScaling = false
    var aspectRatioIndex = 0
    var outputScaleIndex = 0
    var freeScale = false
    var frameSkipIndex = 0
    var clone = false
    var transparent = false
    var flipHorizontal = false
    var flipVertical = false
    var vertical = false
    var captureCursor = false
    var bilinear = false
    var maxCaptureRate = false
    var shaderActive = true
    var crop = CropInsets()
    /// Desktop "Lock Current Area": captured area in display pixels (top-left origin), or nil.
    var lockedArea: CGRect? = nil
    var paused = false

    var pixelSize: Float { pixelSizes[pixelSizeIndex].size }
    var aspectRatio: Float { aspectRatios[aspectRatioIndex].ratio }
    var outputScale: Float { outputScales[outputScaleIndex].scale }
    var frameSkip: Int { frameSkips[frameSkipIndex].skip }

    /// ShaderGlass' output scale factors (CaptureManager::UpdateOutputSize): captured pixels per output pixel.
    /// (0, 0) means "Stretch".
    var outputScaleFactors: (w: Float, h: Float) {
        let ar = aspectRatio
        let os = outputScale
        if ar == 0 { return (0, 0) }
        if vertical { return (1.0 / os, 1.0 / ar / os) }
        return (ar / os, 1.0 / os)
    }
}
