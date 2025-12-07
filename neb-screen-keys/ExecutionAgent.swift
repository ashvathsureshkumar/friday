//
//  ExecutionAgent.swift
//  neb-screen-keys
//
//  Consumer that processes annotations and determines if automation should be triggered
//

import Cocoa
import CryptoKit

final class ExecutionAgent {
    private let stateStore: TaskStateStore
    private let overlay: OverlayController
    private let executor: ExecutorService

    /// The annotation currently being shown to the user (for use when executing)
    private var currentAnnotation: AnnotatedContext?

    init(stateStore: TaskStateStore, overlay: OverlayController, executor: ExecutorService) {
        self.stateStore = stateStore
        self.overlay = overlay
        self.executor = executor
    }

    /// Get the current annotation being displayed (for execution without re-annotating)
    func getCurrentAnnotation() -> AnnotatedContext? {
        return currentAnnotation
    }

    /// Process an annotation and determine if it requires action
    /// If yes, shows the overlay and generates a suggestion
    func processAnnotation(_ annotation: AnnotatedContext) {
        Logger.shared.log(.executor, "Executor consumed event: '\(annotation.taskLabel)' [activity: \(annotation.activityType)]")

        // Generate stable task ID
        let taskId = stableTaskId(for: annotation)

        // Check if task was previously declined or completed
        if stateStore.wasDeclined(taskId) {
            Logger.shared.log(.executor, "Task was declined previously, skipping. ID: \(taskId.prefix(8))...")
            return
        }

        if stateStore.wasCompleted(taskId) {
            Logger.shared.log(.executor, "Task was completed previously, skipping. ID: \(taskId.prefix(8))...")
            return
        }

        // Check if this is a new task
        let isNew = stateStore.updateCurrent(taskId: taskId)

        if isNew {
            Logger.shared.log(.executor, "New task detected: '\(annotation.taskLabel)' [ID: \(taskId.prefix(8))...]")

            // Filter based on activity type (determined by Annotator)
            let filterResult = filterByActivityType(annotation)

            switch filterResult {
            case .reject(let reason):
                Logger.shared.log(.executor, "REJECT: \(reason)")
                return

            case .act(let reason):
                Logger.shared.log(.executor, "ACT: \(reason)")
                Logger.shared.log(.executor, "💡 Generated suggestion: '\(suggestion)'")
                DispatchQueue.main.async { [weak self] in
                    self?.showOverlayAndGenerateSuggestion(for: annotation)
                }
            }
        } else {
            Logger.shared.log(.executor, "Task already known, overlay remains visible")
        }
    }

    /// Generate stable task ID from annotation
    private func stableTaskId(for context: AnnotatedContext) -> String {
        let raw = "\(context.taskLabel)|\(context.app)|\(context.windowTitle)"
        let hash = SHA256.hash(data: raw.data(using: .utf8) ?? Data())
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Show overlay and generate suggestion based on popup style
    private func showOverlayAndGenerateSuggestion(for annotation: AnnotatedContext) {
        Logger.shared.log(.executor, "Showing popup style: \(annotation.popupStyle)")

        // Store annotation for later use when executing
        currentAnnotation = annotation

        switch annotation.popupStyle {
        case .cursor:
            // Cursor-following popup - show suggestion near mouse with keyboard shortcuts
            overlay.showSuggestion(text: "⌘Y Accept | ⌘N Dismiss\nThinking...", enableKeyboardShortcuts: true)

            // Generate suggestion asynchronously
            executor.generateSuggestionPreview(task: annotation) { [weak self] suggestion in
                DispatchQueue.main.async {
                    // Update text with suggestion, keep keyboard shortcut hints
                    self?.overlay.showSuggestion(text: "⌘Y Accept | ⌘N Dismiss\n\(suggestion)", enableKeyboardShortcuts: true)
                }
            }

        case .notification:
            // Top-right notification - show decision panel with buttons
            // Show initial state with "Thinking..."
            overlay.showDecision(text: "\(annotation.taskLabel)\nThinking...")

            // Generate suggestion and update panel
            executor.generateSuggestionPreview(task: annotation) { [weak self] suggestion in
                DispatchQueue.main.async {
                    // Update with the actual suggestion so user knows what will happen
                    self?.overlay.showDecision(text: "\(annotation.taskLabel)\n\(suggestion)")
                }
            }
        }
    }

    // MARK: - Activity Type Filter

    /// Filter result based on activity type
    enum FilterResult {
        case reject(reason: String)  // Don't show overlay
        case act(reason: String)     // Show overlay and offer help
    }

    /// Filter based on activity type from the Annotator
    /// This is instant (no API call) since activity_type was already determined by the Annotator
    func filterByActivityType(_ annotation: AnnotatedContext) -> FilterResult {
        // Low confidence - annotator isn't sure what's happening
        if annotation.confidence < 0.4 {
            return .reject(reason: "Low confidence (\(Int(annotation.confidence * 100))%)")
        }

        // Route based on activity type (already classified by Annotator LLM)
        switch annotation.activityType {
        case .blocked:
            return .act(reason: "User is blocked (errors/failures detected)")

        case .helpSeeking:
            return .act(reason: "User is seeking help")

        case .tedious:
            return .act(reason: "Tedious task detected")

        case .passive:
            return .reject(reason: "Passive activity (reading/browsing)")

        case .meeting:
            return .reject(reason: "User is in a meeting")

        case .productive:
            return .reject(reason: "User is productive (in flow)")
        }
    }
}
