//
//  EnvLoader.swift
//  neb-screen-keys
//

import Foundation

final class EnvLoader {
    static let shared = EnvLoader()
    private init() {}

    func load() {
        let fm = FileManager.default
        var paths: [URL] = []

        if let home = fm.homeDirectoryForCurrentUser as URL? {
            let configPath = home.appendingPathComponent(".config/neb-screen-keys/.env")
            paths.append(configPath)
        }

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".env")
        paths.append(cwd)

        for url in paths {
            if fm.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                parseAndSet(text: text)
                break
            }
        }
    }

    private func parseAndSet(text: String) {
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            setenv(key, value, 1)
        }
    }
}

