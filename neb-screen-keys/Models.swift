//
//  Models.swift
//  neb-screen-keys
//

import Cocoa

struct ScreenFrame {
    let image: NSImage
    let appName: String
    let windowTitle: String
}

/// Activity type classification from the Annotator
/// Used by pre-filter to determine if automation should be triggered
enum ActivityType: String, Codable {
    case blocked       // User is stuck: errors, failures, connection refused
    case helpSeeking   // User is searching for solutions: googling errors, Stack Overflow
    case tedious       // Repetitive task that automation could speed up
    case passive       // Reading docs, watching video, casual browsing
    case meeting       // Video call, screen sharing
    case productive    // Actively coding/writing in flow state

    /// Map from JSON string to enum (handles snake_case from API)
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        // Handle snake_case from API - default to passive (conservative) if unknown
        switch rawValue.lowercased().replacingOccurrences(of: "_", with: "") {
        case "blocked": self = .blocked
        case "helpseeking": self = .helpSeeking
        case "tedious": self = .tedious
        case "passive": self = .passive
        case "meeting": self = .meeting
        case "productive": self = .productive
        default: self = .passive  // Conservative default: don't interrupt
        }
    }
}

/// Popup style for showing automation suggestions
/// Determined by the Annotator based on whether action is cursor-contextual or app-wide
enum PopupStyle: String, Codable {
    case cursor       // Follow mouse - action is specific to cursor location
    case notification // Top-right - action is app-wide or general

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        switch rawValue.lowercased() {
        case "cursor": self = .cursor
        case "notification": self = .notification
        default: self = .notification  // Default to less intrusive
        }
    }
}

struct AnnotatedContext: Codable {
    let taskLabel: String
    let confidence: Double
    let summary: String
    let activityType: ActivityType
    let popupStyle: PopupStyle
    let app: String
    let windowTitle: String
    let timestamp: Date
}

final class TaskStateStore {
    private(set) var currentTaskId: String?
    private var declinedTasks = Set<String>()
    private var completedTasks = Set<String>()

    func updateCurrent(taskId: String) -> Bool {
        guard taskId != currentTaskId else { return false }
        currentTaskId = taskId
        return true
    }

    func decline(taskId: String) {
        declinedTasks.insert(taskId)
    }

    func wasDeclined(_ taskId: String) -> Bool {
        declinedTasks.contains(taskId)
    }

    func markCompleted(taskId: String) {
        completedTasks.insert(taskId)
    }

    func wasCompleted(_ taskId: String) -> Bool {
        completedTasks.contains(taskId)
    }
}

// MARK: - Annotation Buffer Service

/// Simplified annotation buffer that directly notifies consumers
actor AnnotationBufferService {
    /// Callback to notify Nebula consumer
    private var nebulaHandler: ((AnnotatedContext) -> Void)?
    
    /// Callback to notify Execution Agent consumer
    private var executionHandler: ((AnnotatedContext) -> Void)?
    
    /// Register handler for Nebula consumer
    func setNebulaHandler(_ handler: @escaping (AnnotatedContext) -> Void) {
        nebulaHandler = handler
        Logger.shared.log(.stream, "Nebula handler registered")
    }
    
    /// Register handler for Execution Agent consumer
    func setExecutionHandler(_ handler: @escaping (AnnotatedContext) -> Void) {
        executionHandler = handler
        Logger.shared.log(.stream, "Execution Agent handler registered")
    }
    
    /// Publish an annotation to all registered consumers
    func publish(_ annotation: AnnotatedContext) {
        Logger.shared.log(.stream, "Publishing annotation: '\(annotation.taskLabel)'")
        
        // Directly call registered handlers (simpler than AsyncStream)
        if let nebulaHandler = nebulaHandler {
            nebulaHandler(annotation)
        }
        
        if let executionHandler = executionHandler {
            executionHandler(annotation)
        }
    }
}

