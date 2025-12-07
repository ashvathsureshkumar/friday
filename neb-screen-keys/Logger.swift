//
//  Logger.swift
//  neb-screen-keys
//

import Foundation

final class Logger {
    static let shared = Logger()
    private init() {}

    func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[neb] \(ts) \(message)")
    }
}

