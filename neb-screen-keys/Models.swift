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

struct AnnotatedContext: Codable {
    let taskLabel: String
    let confidence: Double
    let summary: String
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

