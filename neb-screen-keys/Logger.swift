//
//  Logger.swift
//  neb-screen-keys
//

import Foundation

/// Log categories for different system components
enum LogCategory: String {
    case event = "Event"
    case buffer = "Buffer"
    case annotator = "Annotator"
    case executor = "Executor"
    case nebula = "Nebula"
    case flow = "Flow"
    case capture = "Capture"
    case stream = "Stream"
    case system = "System"
}

final class Logger {
    static let shared = Logger()
    private init() {}

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Log a message with category
    /// - Parameters:
    ///   - category: The log category
    ///   - message: The message to log
    func log(_ category: LogCategory, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        print("[\(timestamp)] [\(category.rawValue)] \(message)")
    }

    /// Log a message without category (legacy support)
    /// - Parameter message: The message to log
    func log(_ message: String) {
        log(.system, message)
    }
}

