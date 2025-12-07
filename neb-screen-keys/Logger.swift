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
    case system = "System"

    var emoji: String {
        switch self {
        case .event: return "⌨️"
        case .buffer: return "📦"
        case .annotator: return "🧠"
        case .executor: return "⚡"
        case .nebula: return "☁️"
        case .flow: return "🔄"
        case .capture: return "📸"
        case .system: return "⚙️"
        }
    }
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
        print("[\(timestamp)] [\(category.rawValue)] \(category.emoji) \(message)")
    }

    /// Log a message without category (legacy support)
    /// - Parameter message: The message to log
    func log(_ message: String) {
        log(.system, message)
    }
}

