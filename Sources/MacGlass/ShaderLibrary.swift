// MacGlass - shader libraries, preset browser tree, path resolution and custom imports.
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A preset in one of the libraries.
struct PresetEntry: Hashable {
    /// "<Library>/<relative path>", e.g. "RetroArch/crt/crt-geom.slangp".
    let key: String
    /// Name shown in the browser.
    let label: String
    let url: URL

    /// Short name for the title bar ("crt-geom").
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// A folder in the browser tree.
final class ShaderFolder {
    let name: String
    let path: String // key prefix, e.g. "RetroArch/crt"
    var folders: [ShaderFolder] = []
    var presets: [PresetEntry] = []

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    var isEmpty: Bool { folders.isEmpty && presets.isEmpty }

    func allPresets() -> [PresetEntry] {
        var result = presets
        for f in folders { result += f.allPresets() }
        return result
    }
}

enum ShaderLibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

final class ShaderLibrary {
    static let retroArchName = "RetroArch"
    static let retroCrisisName = "Retro_Crisis"
    static let customName = "Custom_Shader"

    /// Folders that only hold shader sources, old variants or need HDR output (as in DeckGlass;
    /// Mega Bezel stays visible because librashader runs it).
    static let hiddenDirs: Set<String> = ["shaders", "shader", "old", "hooks", "resources", "include", "includes",
                                          "hdr", "test", "__macosx"]

    /// Folder with the bundled shaders (".../Resources/Shaders"). Can be overridden with MACGLASS_SHADERS.
    let bundledRoot: URL
    let retroArchRoot: URL
    let retroCrisisRoot: URL
    let customRoot: URL
    /// Where resolved copies of presets are written.
    let resolvedRoot: URL

    private(set) var root = ShaderFolder(name: "", path: "")
    private(set) var allPresets: [PresetEntry] = []
    private var byKey: [String: PresetEntry] = [:]

    static func defaultBundledRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["MACGLASS_SHADERS"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("Shaders", isDirectory: true)
    }

    static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacGlass", isDirectory: true)
    }

    init(bundledRoot: URL = ShaderLibrary.defaultBundledRoot(), customRoot: URL? = nil) {
        self.bundledRoot = bundledRoot
        // Same layout as RetroArch / DeckGlass, so Retro Crisis' "../../../shaders_slang/..." paths resolve as written.
        retroArchRoot = bundledRoot.appendingPathComponent("shaders_slang", isDirectory: true)
        retroCrisisRoot = bundledRoot.appendingPathComponent("rc/retro crisis", isDirectory: true)
        self.customRoot = customRoot ?? ShaderLibrary.appSupportDir().appendingPathComponent(ShaderLibrary.customName, isDirectory: true)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        resolvedRoot = caches.appendingPathComponent("MacGlass/resolved", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.customRoot, withIntermediateDirectories: true)
    }

    var libraries: [(String, URL)] {
        [(ShaderLibrary.retroArchName, retroArchRoot),
         (ShaderLibrary.retroCrisisName, retroCrisisRoot),
         (ShaderLibrary.customName, customRoot)]
    }

    // MARK: - Scanning

    /// Rebuilds the browser tree (call again after imports or when the custom folder changed).
    func rescan() {
        let top = ShaderFolder(name: "", path: "")
        for (name, url) in libraries {
            let node = scan(library: name, root: url, rel: "") ?? ShaderFolder(name: name, path: name)
            top.folders.append(node)
        }
        root = top
        allPresets = top.allPresets()
        byKey = Dictionary(allPresets.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func scan(library: String, root: URL, rel: String) -> ShaderFolder? {
        let dir = rel.isEmpty ? root : root.appendingPathComponent(rel, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                          options: []) else { return nil }
        let sorted = entries.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        let node = ShaderFolder(name: rel.isEmpty ? library : (rel as NSString).lastPathComponent,
                                path: rel.isEmpty ? library : "\(library)/\(rel)")
        var stems: [String] = []
        for e in sorted {
            let name = e.lastPathComponent
            if name.hasPrefix(".") || name.hasPrefix("._") { continue }
            let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if ShaderLibrary.hiddenDirs.contains(name.lowercased()) { continue }
                if let sub = scan(library: library, root: root, rel: rel.isEmpty ? name : "\(rel)/\(name)") {
                    node.folders.append(sub)
                }
            } else if name.lowercased().hasSuffix(".slangp") {
                stems.append(String(name.dropLast(7)))
            }
        }
        if node.folders.isEmpty && stems.isEmpty { return nil }
        let labels = ShaderLibrary.tidyLabels(stems)
        node.presets = stems.map { st in
            let relFile = rel.isEmpty ? "\(st).slangp" : "\(rel)/\(st).slangp"
            return PresetEntry(key: "\(library)/\(relFile)", label: labels[st] ?? st,
                               url: root.appendingPathComponent(relFile))
        }.sorted { $0.label.lowercased() < $1.label.lowercased() }
        return node
    }

    /// Strips a prefix shared by every preset in a folder, e.g. "RC GDV-NTSC - " (as in DeckGlass).
    static func tidyLabels(_ names: [String]) -> [String: String] {
        guard names.count >= 2 else { return Dictionary(names.map { ($0, $0) }, uniquingKeysWith: { a, _ in a }) }
        var prefix = names[0]
        for n in names.dropFirst() {
            while !n.hasPrefix(prefix) { prefix.removeLast() }
        }
        guard let cutRange = prefix.range(of: " - ", options: .backwards), cutRange.lowerBound > prefix.startIndex else {
            return Dictionary(names.map { ($0, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let cut = prefix.distance(from: prefix.startIndex, to: cutRange.upperBound)
        return Dictionary(names.map { n in
            let rest = String(n.dropFirst(cut)).trimmingCharacters(in: .whitespaces)
            return (n, rest.isEmpty ? n : rest)
        }, uniquingKeysWith: { a, _ in a })
    }

    func preset(forKey key: String) -> PresetEntry? {
        if let p = byKey[key] { return p }
        // Not scanned (e.g. hidden folder): build it from the key.
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let lib = libraries.first(where: { $0.0 == parts[0] }) else { return nil }
        let url = lib.1.appendingPathComponent(parts[1])
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return PresetEntry(key: key, label: url.deletingPathExtension().lastPathComponent, url: url)
    }

    /// Entry for a preset file anywhere on disk (e.g. from a profile).
    func preset(forFile url: URL) -> PresetEntry {
        let path = url.standardizedFileURL.path
        for (name, root) in libraries {
            let rootPath = root.standardizedFileURL.path + "/"
            if path.hasPrefix(rootPath) {
                let key = "\(name)/\(path.dropFirst(rootPath.count))"
                if let p = byKey[key] { return p }
                return PresetEntry(key: key, label: url.deletingPathExtension().lastPathComponent, url: url)
            }
        }
        return PresetEntry(key: path, label: url.deletingPathExtension().lastPathComponent, url: url)
    }

    // MARK: - Path resolution

    static let pathExtensions: Set<String> = ["slang", "slangp", "png", "jpg", "jpeg", "bmp", "tga", "gif", "tif", "tiff"]

    /// Finds a referenced file: as written, case-insensitively, or inside the bundled libretro shaders
    /// (by the longest matching tail of the path, ".../shaders_slang/<rest>" first) - like DeckGlass.
    func resolve(_ written: String, relativeTo dir: URL) -> URL? {
        let raw = written.replacingOccurrences(of: "\\", with: "/")
        let joined = raw.hasPrefix("/") ? raw : dir.appendingPathComponent(raw).path
        let normalized = (joined as NSString).standardizingPath
        if let found = ShaderLibrary.resolveCase(normalized) { return URL(fileURLWithPath: found) }

        let parts = normalized.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        var tails: [[String]] = []
        let lowered = parts.map { $0.lowercased() }
        if let idx = lowered.lastIndex(of: "shaders_slang") {
            tails.append(Array(parts[(idx + 1)...]))
        }
        if parts.count >= 2 {
            for i in 0..<(parts.count - 1) where parts.count - i >= 2 {
                tails.append(Array(parts[i...]))
            }
        }
        for root in [retroArchRoot] {
            for tail in tails where !tail.isEmpty {
                let candidate = root.path + "/" + tail.joined(separator: "/")
                if let found = ShaderLibrary.resolveCase(candidate) { return URL(fileURLWithPath: found) }
            }
        }
        return nil
    }

    /// Case-insensitive lookup (presets are often authored on Windows).
    static func resolveCase(_ path: String) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return path }
        var current = path.hasPrefix("/") ? "/" : "."
        for part in path.split(separator: "/").map(String.init) where !part.isEmpty {
            let next = (current as NSString).appendingPathComponent(part)
            if fm.fileExists(atPath: next) {
                current = next
                continue
            }
            guard let entries = try? fm.contentsOfDirectory(atPath: current),
                  let match = entries.first(where: { $0.lowercased() == part.lowercased() }) else { return nil }
            current = (current as NSString).appendingPathComponent(match)
        }
        return fm.fileExists(atPath: current) ? current : nil
    }

    /// A parsed `key = value` line whose value looks like a file path.
    private struct PathLine {
        let key: String
        let value: String
    }

    private static func parsePathLine(_ line: String) -> PathLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("//") { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        var rest = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        var value: String
        if rest.hasPrefix("\"") {
            rest.removeFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            value = String(rest[..<end])
        } else {
            value = String(rest.prefix { !$0.isWhitespace && $0 != "#" && $0 != ";" })
            if let r = value.range(of: "//") { value = String(value[..<r.lowerBound]) }
        }
        guard !key.isEmpty, !value.isEmpty, !value.contains("$") else { return nil }
        let ext = (value as NSString).pathExtension.lowercased()
        guard pathExtensions.contains(ext) else { return nil }
        return PathLine(key: key, value: value)
    }

    private static func parseReference(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#reference") else { return nil }
        var rest = trimmed.dropFirst("#reference".count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") {
            rest.removeFirst()
            if let end = rest.firstIndex(of: "\"") { rest = String(rest[..<end]) }
        }
        return rest.isEmpty ? nil : rest
    }

    private static func readLines(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// True if every file referenced by the preset (and its #reference chain) exists as written.
    private func resolvesAsWritten(_ url: URL, depth: Int = 0) -> Bool {
        guard depth < 16, let lines = try? ShaderLibrary.readLines(url) else { return true }
        let dir = url.deletingLastPathComponent()
        for line in lines {
            if let ref = ShaderLibrary.parseReference(line) {
                let target = URL(fileURLWithPath: ((ref.hasPrefix("/") ? ref : dir.appendingPathComponent(ref).path) as NSString).standardizingPath)
                if !FileManager.default.fileExists(atPath: target.path) || !resolvesAsWritten(target, depth: depth + 1) {
                    return false
                }
            } else if let pl = ShaderLibrary.parsePathLine(line) {
                let target = ((pl.value.hasPrefix("/") ? pl.value : dir.appendingPathComponent(pl.value).path) as NSString).standardizingPath
                if !FileManager.default.fileExists(atPath: target) { return false }
            }
        }
        return true
    }

    /// Returns a preset path librashader can load. Presets whose references do not resolve as written
    /// (e.g. "shaders_slang/..." paths in custom or Retro Crisis presets, Windows letter case) are
    /// rewritten into a cache folder with absolute paths, resolved against the bundled libretro shaders.
    func loadablePath(for preset: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: preset.path) else {
            throw ShaderLibraryError.message("Preset not found: \(preset.path)")
        }
        if resolvesAsWritten(preset) { return preset }
        let session = resolvedRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Remove older resolved copies.
        if let old = try? FileManager.default.contentsOfDirectory(at: resolvedRoot, includingPropertiesForKeys: nil) {
            for o in old { try? FileManager.default.removeItem(at: o) }
        }
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        var counter = 0
        return try rewrite(preset, into: session, counter: &counter, depth: 0)
    }

    private func rewrite(_ url: URL, into dir: URL, counter: inout Int, depth: Int) throws -> URL {
        guard depth < 16 else { throw ShaderLibraryError.message("Too many nested #reference lines in \(url.lastPathComponent)") }
        let lines = try ShaderLibrary.readLines(url)
        let srcDir = url.deletingLastPathComponent()
        var out: [String] = []
        for line in lines {
            if let ref = ShaderLibrary.parseReference(line) {
                guard let target = resolve(ref, relativeTo: srcDir) else {
                    throw ShaderLibraryError.message("Referenced preset not found: \(ref)\n(in \(url.lastPathComponent))")
                }
                let copy = try rewrite(target, into: dir, counter: &counter, depth: depth + 1)
                out.append("#reference \"\(copy.path)\"")
            } else if let pl = ShaderLibrary.parsePathLine(line) {
                if let target = resolve(pl.value, relativeTo: srcDir) {
                    out.append("\(pl.key) = \"\(target.path)\"")
                } else {
                    NSLog("MacGlass: unresolved path \(pl.value) in \(url.path)")
                    out.append(line)
                }
            } else {
                out.append(line)
            }
        }
        counter += 1
        let name = "\(counter)-\(url.lastPathComponent)"
        let dest = dir.appendingPathComponent(name)
        try out.joined(separator: "\n").write(to: dest, atomically: true, encoding: .utf8)
        return dest
    }

    // MARK: - Import

    /// Copies a .slangp or .slang (with everything it references that is not part of the bundled
    /// libretro shaders) into the Custom_Shader folder and returns the imported preset.
    func importShader(from source: URL) throws -> PresetEntry {
        let ext = source.pathExtension.lowercased()
        guard ext == "slangp" || ext == "slang" else {
            throw ShaderLibraryError.message("Only .slangp and .slang files can be imported.")
        }
        var files = Set<String>()
        try collect(source, ext: ext, into: &files, depth: 0)
        let paths = files.sorted()
        let commonDir = ShaderLibrary.commonDirectory(paths)

        let stem = source.deletingPathExtension().lastPathComponent
        var destRoot = customRoot.appendingPathComponent(stem, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: destRoot.path) {
            destRoot = customRoot.appendingPathComponent("\(stem) \(n)", isDirectory: true)
            n += 1
        }
        for p in paths {
            let rel = String(p.dropFirst(commonDir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let dest = destRoot.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: p), to: dest)
        }
        let srcRel = String(source.standardizedFileURL.path.dropFirst(commonDir.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var presetURL = destRoot.appendingPathComponent(srcRel)
        if ext == "slang" {
            // A single shader becomes a one-pass preset next to it.
            let preset = presetURL.deletingPathExtension().appendingPathExtension("slangp")
            let text = "shaders = 1\nshader0 = \"\(presetURL.lastPathComponent)\"\nfilter_linear0 = false\nscale_type0 = viewport\n"
            try text.write(to: preset, atomically: true, encoding: .utf8)
            presetURL = preset
        }
        rescan()
        return preset(forFile: presetURL)
    }

    private func collect(_ url: URL, ext: String, into files: inout Set<String>, depth: Int) throws {
        let path = url.standardizedFileURL.path
        guard depth < 32, !files.contains(path) else { return }
        // Files of the bundled libraries are found at runtime, no need to copy them.
        if path.hasPrefix(bundledRoot.standardizedFileURL.path + "/") { return }
        files.insert(path)
        let dir = url.deletingLastPathComponent()
        switch ext {
        case "slangp":
            for line in try ShaderLibrary.readLines(url) {
                if let ref = ShaderLibrary.parseReference(line), let t = resolve(ref, relativeTo: dir) {
                    try collect(t, ext: "slangp", into: &files, depth: depth + 1)
                } else if let pl = ShaderLibrary.parsePathLine(line), let t = resolve(pl.value, relativeTo: dir) {
                    try collect(t, ext: t.pathExtension.lowercased(), into: &files, depth: depth + 1)
                }
            }
        case "slang", "h", "inc", "glsl":
            for line in try ShaderLibrary.readLines(url) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("#include") else { continue }
                let parts = trimmed.components(separatedBy: "\"")
                guard parts.count >= 2 else { continue }
                if let t = resolve(parts[1], relativeTo: dir) {
                    try collect(t, ext: "slang", into: &files, depth: depth + 1)
                }
            }
        default:
            break
        }
    }

    static func commonDirectory(_ paths: [String]) -> String {
        guard var common = paths.first.map({ ($0 as NSString).deletingLastPathComponent }) else { return "/" }
        for p in paths.dropFirst() {
            let dir = (p as NSString).deletingLastPathComponent
            while !(dir == common || dir.hasPrefix(common.hasSuffix("/") ? common : common + "/")) {
                common = (common as NSString).deletingLastPathComponent
                if common == "/" || common.isEmpty { return "/" }
            }
        }
        return common
    }
}
