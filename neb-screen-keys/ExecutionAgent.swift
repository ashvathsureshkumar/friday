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
    
    init(stateStore: TaskStateStore, overlay: OverlayController, executor: ExecutorService) {
        self.stateStore = stateStore
        self.overlay = overlay
        self.executor = executor
    }
    
    /// Process an annotation and determine if it requires action
    /// If yes, shows the overlay and generates a suggestion
    func processAnnotation(_ annotation: AnnotatedContext) {
        Logger.shared.log(.executor, "Executor consumed event: '\(annotation.taskLabel)'")
        
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
            
            // Show decision panel on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let decisionText = "Execute automation for:\n\(annotation.taskLabel)"
                self.overlay.showDecision(text: decisionText)
                
                // Show loading state while generating suggestion
                self.overlay.showSuggestion(text: "Thinking...")
            }
            
            // Generate and show AI suggestion preview asynchronously
            executor.generateSuggestionPreview(task: annotation) { [weak self] suggestion in
                DispatchQueue.main.async {
                    self?.overlay.showSuggestion(text: suggestion)
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
}
