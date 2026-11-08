// MacGlass - profiles (Processing > Load profile... / Save profile as...), in ShaderGlass' "Key \"value\"" format.
// SPDX-License-Identifier: GPL-3.0-only
// Portions derived from ShaderGlass (https://github.com/mausimus/ShaderGlass), Copyright (C) 2021-2025 mausimus, GPL-3.0.
// MacGlass is an independent, unofficial project and is not affiliated with ShaderGlass.
import Foundation

struct Profile {
    var entries: [(String, String)] = []

    subscript(key: String) -> String? {
        entries.last(where: { $0.0 == key })?.1
    }

    mutating func set(_ key: String, _ value: String) {
        entries.append((key, value))
    }

    func bool(_ key: String) -> Bool? {
        guard let v = self[key] else { return nil }
        return v == "1" || v.lowercased() == "true"
    }

    func text() -> String {
        entries.map { "\($0.0) \"\($0.1.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: "\n") + "\n"
    }

    static func parse(_ text: String) -> Profile {
        var p = Profile()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space])
            var value = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            p.set(key, value)
        }
        return p
    }

    static func load(_ url: URL) throws -> Profile {
        parse(try String(contentsOf: url, encoding: .utf8))
    }

    func save(_ url: URL) throws {
        try text().write(to: url, atomically: true, encoding: .utf8)
    }
}
