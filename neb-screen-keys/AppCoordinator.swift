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
    private let contextBuffer = ContextBufferService()

    private let annotator: AnnotatorService
    private let executor: ExecutorService
    private let nebula: NebulaClient

    // MARK: - Producer Flow State
    private var lastScreenCaptureTime: Date?
    private let screenCaptureThrottleInterval: TimeInterval = 0.5 // 500ms throttle
    private var consumerTask: Task<Void, Never>?

    init(grokApiKey: String = ProcessInfo.processInfo.environment["GROK_API_KEY"] ?? "",
         nebulaApiKey: String = ProcessInfo.processInfo.environment["NEBULA_API_KEY"] ?? "",
         nebulaCollection: String = ProcessInfo.processInfo.environment["NEBULA_COLLECTION_ID"] ?? "") {
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
        Permissions.ensure { [weak self] screen, ax in
            guard let self = self else { return }
            if screen == .denied {
                Logger.shared.log("Screen Recording permission not granted; capture will fail.")
            }
            if ax == .denied {
                Logger.shared.log("Accessibility permission not granted; keystroke monitoring and automation will fail.")
            }

            // PRODUCER FLOW: Event monitors push to buffer instead of direct annotation
            self.eventMonitor.onShortcut = { [weak self] shortcut in
                self?.handleProducerEvent(shortcut: shortcut)
            }
            self.eventMonitor.start()

            self.keystrokeMonitor.onKeyEvent = { [weak self] in
                self?.handleKeystroke()
            }
            self.keystrokeMonitor.start()

            // CONSUMER FLOW: Start the periodic AI processing loop
            self.startAnnotatorLoop()

            // Initial screen capture on launch
            self.captureAndBuffer(reason: "launch")
        }
    }

    // MARK: - Producer Flow (High Speed)

    /// Handle shortcut events by buffering keystroke marker and triggering screen capture
    private func handleProducerEvent(shortcut: String) {
        Task { [weak self] in
            guard let self = self else { return }
            await self.contextBuffer.append(keystrokes: "[SHORTCUT:\(shortcut)]")
            self.captureAndBuffer(reason: "shortcut")
        }
    }

    /// Handle keystroke events by buffering and triggering throttled screen capture
    private func handleKeystroke() {
        Task { [weak self] in
            guard let self = self else { return }
            await self.contextBuffer.append(keystrokes: ".")
            self.captureAndBuffer(reason: "keystroke")
        }
    }

    /// Capture screen and buffer it (with throttling)
    private func captureAndBuffer(reason: String) {
        // Throttle screen captures to avoid performance hits
        let now = Date()
        if let lastCapture = lastScreenCaptureTime,
           now.timeIntervalSince(lastCapture) < screenCaptureThrottleInterval {
            // Skip this capture, too soon
            Logger.shared.log(.capture, "⏭️ Capture skipped (throttled). Reason: \(reason)")
            return
        }

        lastScreenCaptureTime = now
        Logger.shared.log(.capture, "🎬 Initiating screen capture. Reason: \(reason)")

        Task { [weak self] in
            guard let self = self else { return }
            if let frame = await self.captureService.captureActiveScreen() {
                await self.contextBuffer.updateLatestScreen(frame)
                Logger.shared.log(.capture, "✅ Screen captured and buffered (\(reason))")
            } else {
                Logger.shared.log(.capture, "❌ Screen capture failed (\(reason))")
            }
        }
    }

    // MARK: - Consumer Flow (AI Pace)

    /// Start the periodic annotation loop that consumes buffered data
    private func startAnnotatorLoop() {
        Logger.shared.log(.flow, "🔄 Consumer loop starting (3s interval)...")

        consumerTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                // Wait for interval (e.g., 3 seconds)
                try? await Task.sleep(nanoseconds: 3_000_000_000)

                Logger.shared.log(.flow, "🔔 Loop tick. Checking buffer...")

                // Check if buffer has data
                let hasData = await self.contextBuffer.hasData()
                guard hasData else {
                    Logger.shared.log(.flow, "💤 Buffer empty, skipping annotation")
                    continue
                }

                // Consume buffer
                guard let batch = await self.contextBuffer.consumeAndClear() else {
                    Logger.shared.log(.flow, "⚠️ Buffer had data but consumeAndClear returned nil")
                    continue
                }

                Logger.shared.log(.flow, "📋 Processing batch: \(batch.keystrokes.count) chars, screen=\(batch.screenFrame != nil)")

                // Process with annotator
                await self.processBufferBatch(batch)
            }

            Logger.shared.log(.flow, "🛑 Consumer loop stopped")
        }
    }

    /// Process a consumed buffer batch through the annotator
    private func processBufferBatch(_ batch: BufferBatch) async {
        Logger.shared.log(.flow, "➡️ Sending batch to annotator...")

        let result = await self.annotator.annotate(batch: batch)
        switch result {
        case .failure(let error):
            Logger.shared.log(.flow, "❌ Annotation failed: \(error.localizedDescription)")
        case .success(let context):
            let taskId = self.stableTaskId(for: context)

            if stateStore.wasDeclined(taskId) {
                Logger.shared.log(.flow, "⏭️ Task was declined previously, skipping. ID: \(taskId.prefix(8))...")
                return
            }
            if stateStore.wasCompleted(taskId) {
                Logger.shared.log(.flow, "⏭️ Task was completed previously, skipping. ID: \(taskId.prefix(8))...")
                return
            }

            self.pushToNebula(context: context, taskId: taskId)

            let isNew = stateStore.updateCurrent(taskId: taskId)
            if isNew {
                Logger.shared.log(.flow, "🆕 New task detected: '\(context.taskLabel)' [ID: \(taskId.prefix(8))...]")
                overlay.showSuggestion(text: "Grok can help: \(context.taskLabel)")
                overlay.showDecision(text: "Execute \(context.taskLabel)?")
            } else {
                Logger.shared.log(.flow, "♻️ Task already known, overlay remains visible")
            }
        }
    }

    private func executeCurrentTask() {
        guard let taskId = stateStore.currentTaskId else { return }
        Logger.shared.log("Execute requested for task \(taskId)")
        Task { [weak self] in
            guard let self = self else { return }

            // Consume current buffer state for execution
            let batch = await self.contextBuffer.consumeAndClear()

            // If no batch exists, create one from fresh screen capture
            let executionBatch: BufferBatch
            if let batch = batch {
                executionBatch = batch
            } else if let frame = await self.captureService.captureActiveScreen() {
                executionBatch = BufferBatch(keystrokes: "", screenFrame: frame, timestamp: Date())
            } else {
                Logger.shared.log("Execute failed: Unable to capture screen")
                return
            }

            let result = await self.annotator.annotate(batch: executionBatch)
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

