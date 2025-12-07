//
//  AppCoordinator.swift
//  neb-screen-keys
//

import Cocoa
import CryptoKit

final class AppCoordinator {
    private let stateStore = TaskStateStore()
    private let eventMonitor = EventMonitor()
    private let keystrokeMonitor = KeystrokeMonitor()
    private let captureService = ScreenCaptureService()
    private let overlay = OverlayController()

    private let annotator: AnnotatorService
    private let executor: ExecutorService
    private let nebula: NebulaClient

    init(grokApiKey: String = ProcessInfo.processInfo.environment["GROK_API_KEY"] ?? "",
         nebulaApiKey: String = ProcessInfo.processInfo.environment["NEBULA_API_KEY"] ?? "",
         nebulaCollection: String = ProcessInfo.processInfo.environment["NEBULA_COLLECTION_ID"] ?? "aec926de-022c-47ac-8ae3-ddcd7febf68c") {
        let grok = GrokClient(apiKey: grokApiKey)
        let nebulaClient = NebulaClient(apiKey: nebulaApiKey, collectionId: nebulaCollection)
        self.nebula = nebulaClient
        self.annotator = AnnotatorService(grok: grok, capture: captureService)
        self.executor = ExecutorService(grok: grok, nebula: nebulaClient)

        overlay.onAccept = { [weak self] in self?.executeCurrentTask() }
        overlay.onDecline = { [weak self] in
            if let taskId = self?.stateStore.currentTaskId {
                self?.stateStore.decline(taskId: taskId)
            }
        }
    }

    func start() {
        Logger.shared.log("Coordinator start")
        eventMonitor.onShortcut = { [weak self] _ in
            self?.maybeAnnotate(reason: "shortcut")
        }
        eventMonitor.start()
        keystrokeMonitor.onKeyEvent = { [weak self] in
            self?.maybeAnnotate(reason: "keystroke")
        }
        keystrokeMonitor.start()

        maybeAnnotate(reason: "launch")
    }

    private func maybeAnnotate(reason: String) {
        Task {
            let result = await annotator.annotate()
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                Logger.shared.log("Annotate failed (\(reason)): \(error)")
            case .success(let context):
                let taskId = self.stableTaskId(for: context)
                if stateStore.wasDeclined(taskId) || stateStore.wasCompleted(taskId) { return }
                self.pushToNebula(context: context, taskId: taskId)
                let isNew = stateStore.updateCurrent(taskId: taskId)
                if isNew {
                    Logger.shared.log("New task detected: \(context.taskLabel) [\(taskId)]")
                    overlay.showSuggestion(text: "Grok can help: \(context.taskLabel)")
                    overlay.showDecision(text: "Execute \(context.taskLabel)?")
                }
            }
        }
    }

    private func executeCurrentTask() {
        guard let taskId = stateStore.currentTaskId else { return }
        Logger.shared.log("Execute requested for task \(taskId)")
        Task {
            let result = await annotator.annotate()
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                Logger.shared.log("Annotate before execute failed: \(error)")
            case .success(let context):
                self.executor.planAndExecute(task: context) { execResult in
                    switch execResult {
                    case .failure(let error):
                        Logger.shared.log("Plan/execute failed: \(error)")
                    case .success(let plan):
                        Logger.shared.log("Execution plan stored for \(taskId)")
                        self.stateStore.markCompleted(taskId: taskId)
                        self.pushExecutionResult(taskId: taskId, plan: plan)
                        self.overlay.hideAll()
                    }
                }
            }
        }
    }

    private func stableTaskId(for context: AnnotatedContext) -> String {
        let raw = "\(context.taskLabel)|\(context.app)|\(context.windowTitle)"
        let hash = SHA256.hash(data: raw.data(using: .utf8) ?? Data())
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func pushToNebula(context: AnnotatedContext, taskId: String) {
        let metadata: [String: Any] = [
            "task_id": taskId,
            "task_label": context.taskLabel,
            "app": context.app,
            "window_title": context.windowTitle,
            "confidence": context.confidence,
            "timestamp": context.timestamp.timeIntervalSince1970
        ]
        let content = "Summary: \(context.summary)"
        nebula.addMemory(content: content, metadata: metadata) { result in
            if case .failure(let error) = result {
                print("Nebula addMemory error: \(error.localizedDescription)")
            }
        }
    }

    private func pushExecutionResult(taskId: String, plan: String) {
        let metadata: [String: Any] = [
            "task_id": taskId,
            "type": "execution_plan"
        ]
        nebula.addMemory(content: plan, metadata: metadata) { result in
            if case .failure(let error) = result {
                print("Nebula addMemory (execution) error: \(error.localizedDescription)")
            }
        }
    }
}

