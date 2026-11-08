# MacGlass

> **Early release (0.x):** expect rough edges and please report problems via GitHub issues.

RetroArch slang shaders over any Mac window or the whole desktop, in real time: CRT, scanlines, NTSC, handheld LCDs and more. It works for every game and emulator, not just inside RetroArch. MacGlass is an independent macOS app modelled on [ShaderGlass](https://github.com/mausimus/ShaderGlass) for Windows, built with Swift, Metal, ScreenCaptureKit and [librashader](https://github.com/SnowflakePowered/librashader).

> **Unofficial:** MacGlass is not ShaderGlass and is not affiliated with or endorsed by ShaderGlass or its author mausimus. Please report MacGlass problems only here, never to ShaderGlass.

## Download

Get `MacGlass-<version>.zip` from [Releases](https://github.com/lumen-tools/MacGlass/releases), unzip it and move `MacGlass.app` to Applications. The app runs on Apple Silicon and Intel Macs with macOS 13 Ventura or newer.

The app is not notarized. If macOS says it "is damaged" or "cannot be opened", remove the download quarantine once:

```bash
xattr -dr com.apple.quarantine /Applications/MacGlass.app
```

On first start, macOS asks for **Screen Recording** permission. Take your time: MacGlass shows a hint with a button to System Settings > Privacy & Security > Screen & System Audio Recording. Allow MacGlass there, then reopen it (or choose "Quit & Reopen" if macOS offers it); "Try Again" in the hint checks once more. MacGlass never asks repeatedly on its own. If MacGlass keeps showing the hint although it is switched on in that list (the entry belongs to an older, differently signed version), click **Reset Permission** in the hint, allow MacGlass when macOS asks and choose "Quit & Reopen". The same in Terminal:

```bash
tccutil reset ScreenCapture io.github.lumen-tools.MacGlass
```

## How it works

```
ScreenCaptureKit ─► preprocess (crop, Pixel Size, Bilinear Filter) ─► librashader (.slangp) ─► window / overlay
```

- **Glass** (Output > Mode): the MacGlass window shows the desktop *underneath it* with the shader applied. Move it over a game or emulator, or go fullscreen (⌃⇧G) and the whole display gets the shader. MacGlass' own windows are excluded from the capture, so there is no mirror feedback.
- **Glass on a window** (Input > Window): MacGlass covers the chosen window with the shaded image and follows it. The overlay is click-through, so you keep playing in the window below.
- **Clone**: the captured display, window, capture device or image is shown in MacGlass' own window.
- **Click-through** (Output > Window, or ⌃⇧T): clicks on the picture go to the app below and the window stays on top. The title bar and the window edges stay clickable, so you can still move, resize and close it (the red button quits MacGlass). The default is Solid. Fullscreen in Glass mode is always click-through.

## Shaders

Shader > Choose from Library... (⌘L) opens a browser with three top folders:

- **RetroArch:** the current [libretro slang-shaders](https://github.com/libretro/slang-shaders), including Mega Bezel. HDR shaders, test patterns and source-only folders are hidden.
- **Retro_Crisis:** the newest release of [Retro Crisis GDV-NTSC](https://github.com/RetroCrisis/Retro-Crisis-GDV-NTSC) (GPL-3).
- **Custom_Shader:** your own presets in `~/Library/Application Support/MacGlass/Custom_Shader`. Use Shader > Import custom... for a `.slangp` or `.slang` (it is copied with everything it references), or copy folders there yourself (Shader > Open Custom_Shader Folder, then Rescan in the browser).

Presets that point to RetroArch's shader folder (`shaders_slang/...`), such as presets saved in RetroArch or by Retro Crisis, find those files in the bundled libretro shaders automatically. Windows paths and letter case are handled too.

Shader > Parameters... (⌘K) shows all sliders of the preset. Changes apply immediately and are kept until you choose another preset. Profiles store them.

## Menus

The menus follow ShaderGlass:

| Menu | Items |
| --- | --- |
| Processing | Start, Stop, Pause/Unpause, Global Hotkeys, Toggle Menu, Remember Position, Keep Mac Awake, **Bilinear Filter**, GPU, Renderer, FPS, Advanced (Max Capture Rate), Load / Save / Recent profiles, Set as / Remove default profile |
| Input | Desktop (displays, Lock Current Area), Window, Device, File..., Pixel Size (incl. Adjust for Retina Scale), Crop..., Capture Cursor |
| Output | Mode (Glass / Clone), Window (Solid / Click-through), Flip, Scale (Free, 25%–1000%, Retain), Aspect Ratio Correction, Orientation, Fullscreen, Take Snapshot... |
| Shader | Choose from Library..., Next (n), Random (r), Active, Import custom..., Recent imports, Parameters... |

Single-key shortcuts while the MacGlass window has focus: **n** next shader, **r** random shader, **p** / **o** next / previous pixel size, **space** pause.
Global hotkeys (Processing > Global Hotkeys, changeable): ⌃⇧G Fullscreen, ⌃⇧S Screenshot (saved to Pictures), ⌃⇧T Click-through.

### Pixel Size and Bilinear Filter

**Pixel Size** sets how many captured pixels make up one pixel of the shader input. For example, a game shown at 3× needs x3. Besides the preset sizes, **Custom...** takes any value from 1 to 30 with up to two decimals (e.g. 4.65). With **Adjust for Retina Scale**, the size counts in points instead of pixels.

**Bilinear Filter** (Processing): when the captured image is scaled down to the shader input, MacGlass averages the whole area ("footprint") of each source pixel instead of reading a single point. It does this with n × n bilinear taps, where n = 2…8 depending on the scale. On a picture the emulator scaled up without filtering, this gives the same result as "bilinear filtering in the emulator" and removes the mosaic pattern at non-integer pixel sizes. The shader chain itself is unchanged.

## Limitations

- Capture devices and image files work in Clone mode; Glass applies to the desktop or windows.
- Window capture records the whole window including its title bar; use Input > Crop... to cut it off.
- Heavy presets (e.g. crt-royale, Mega Bezel) cost a lot of GPU time, and loading a big preset pauses the output for a moment while it compiles.
- A few presets do not work in librashader (see its [list of broken shaders](https://github.com/SnowflakePowered/librashader/blob/master/BROKEN_SHADERS.md)). The error is shown when you choose them.

## Building

On a Mac with Xcode (Swift 5.9+), Rust (`rustup`) and the GitHub CLI:

```bash
scripts/build-librashader.sh   # librashader from the tag in LIBRASHADER_VERSION (universal dylib)
scripts/fetch-shaders.sh       # libretro slang-shaders + newest Retro Crisis release
scripts/make-app.sh            # build/MacGlass.app
build/MacGlass.app/Contents/MacOS/MacGlass --selftest build/selftest
```

The C headers in `Sources/LibraBridge/vendor` are those of the same librashader release, and the build checks this. librashader is loaded at runtime through `librashader_ld.h`.

GitHub Actions (`.github/workflows/build.yml`) builds and tests every push on a macOS runner. Raising `VERSION` on `main` (together with `release-notes/<version>.md`) publishes "Version <version>" with `MacGlass-<version>.zip`.

## Credits

- [ShaderGlass](https://github.com/mausimus/ShaderGlass) by mausimus (GPL-3.0): the original for Windows. MacGlass follows its menus and options; the option tables and parts of the processing logic are derived from ShaderGlass, Copyright (C) 2021-2025 mausimus.
- [librashader](https://github.com/SnowflakePowered/librashader) by Ronny Chan (MPL-2.0 / GPL-3.0): shader runtime.
- [libretro slang-shaders](https://github.com/libretro/slang-shaders) and [Retro Crisis GDV-NTSC](https://github.com/RetroCrisis/Retro-Crisis-GDV-NTSC): the shaders, licensed by their authors.
- [DeckGlass](https://github.com/lumen-tools/DeckGlass) and [RetroVisor](https://github.com/dirkwhoffmann/RetroVisor) for ideas on the shader browser, path resolution and capture.

Not affiliated with ShaderGlass, libretro, RetroArch or Retro Crisis. MacGlass was developed with the help of Claude (AI).

## License

GPL-3.0 (see `LICENSE`). The bundled librashader is used under GPL-3.0. Licenses of the bundled components are in `MacGlass.app/Contents/Resources/Licenses`.
