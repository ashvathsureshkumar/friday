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

/// Actor-based annotation buffer that supports multicasting to multiple consumers
actor AnnotationBufferService {
    private var continuations: [UUID: AsyncStream<AnnotatedContext>.Continuation] = [:]
    
    /// Publish an annotation to all active subscribers
    func publish(_ annotation: AnnotatedContext) {
        let activeCount = continuations.count
        Logger.shared.log(.stream, "Broadcasting annotation to \(activeCount) subscriber(s): '\(annotation.taskLabel)'")
        
        // Broadcast to all active continuations
        for (id, continuation) in continuations {
            continuation.yield(annotation)
        }
    }
    
    /// Create a new stream for a consumer to subscribe
    /// Returns an AsyncStream that will receive all published annotations
    func makeStream() -> AsyncStream<AnnotatedContext> {
        let id = UUID()
        
        let stream = AsyncStream<AnnotatedContext> { continuation in
            // Store the continuation for broadcasting
            Task {
                await self.storeContinuation(id: id, continuation: continuation)
            }
            
            // Clean up when stream is terminated
            continuation.onTermination = { @Sendable _ in
                Task {
                    await self.removeContinuation(id: id)
                }
            }
        }
        
        Logger.shared.log(.stream, "New stream created (ID: \(id.uuidString.prefix(8))...). Total subscribers: \(continuations.count + 1)")
        
        return stream
    }
    
    private func storeContinuation(id: UUID, continuation: AsyncStream<AnnotatedContext>.Continuation) {
        continuations[id] = continuation
    }
    
    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
        Logger.shared.log(.stream, "Stream terminated (ID: \(id.uuidString.prefix(8))...). Remaining subscribers: \(continuations.count)")
    }
}

