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
        
        var loaded = false
        for url in paths {
            if fm.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                print("[EnvLoader] Loading .env from: \(url.path)")
                let count = parseAndSet(text: text)
                print("[EnvLoader] Loaded \(count) environment variable(s)")
                loaded = true
                break
            }
        }
        
        if !loaded {
            print("[EnvLoader] ⚠️ WARNING: No .env file found!")
            print("[EnvLoader] Searched paths:")
            for path in paths {
                print("[EnvLoader]   - \(path.path)")
            }
        }
    }

    private func parseAndSet(text: String) -> Int {
        let lines = text.split(whereSeparator: \.isNewline)
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            setenv(key, value, 1)
            
            // Log loaded keys (without values for security)
            if key == "GROK_API_KEY" || key == "NEBULA_API_KEY" {
                let preview = value.isEmpty ? "(EMPTY)" : "\(value.prefix(10))..."
                print("[EnvLoader] Set \(key)=\(preview)")
            }
            count += 1
        }
        return count
    }
}

