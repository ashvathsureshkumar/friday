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
    private let chatOverlay = ChatOverlayController()
    private let contextBuffer = ContextBufferService()
    private let annotationBuffer = AnnotationBufferService()

    private let annotator: AnnotatorService
    private let executor: ExecutorService
    private let nebula: NebulaClient
    private let grok: GrokClient
    private let executionAgent: ExecutionAgent
    private var chatHistory: [GrokMessage] = []

    // MARK: - Producer Flow State
    private var lastScreenCaptureTime: Date?
    private let screenCaptureThrottleInterval: TimeInterval = 0.5 // 500ms throttle
    private var consumerTask: Task<Void, Never>?
    private var nebulaConsumerTask: Task<Void, Never>?
    private var executionConsumerTask: Task<Void, Never>?

    init(grokApiKey: String = ProcessInfo.processInfo.environment["GROK_API_KEY"] ?? "xai-UzAW09X990AA2mTaseOcfIGJT4TO6D4nfYCIpIZVXljlI4oJeWlkNh5KJjxG4yZt3nZR80CPt6TWirJx",
         nebulaApiKey: String = ProcessInfo.processInfo.environment["NEBULA_API_KEY"] ?? "neb_UNUd5XVnQiPsqWODudTIEg==.dbj0j47j59jKf_eDg6KyBgyS_JIGagKaUfNAziDkkvI=",
         nebulaCollection: String = ProcessInfo.processInfo.environment["NEBULA_COLLECTION_ID"] ?? "cd8e4a41-de13-46ac-8229-81c84b96dab3") {

        // Log environment variable status for debugging
        Logger.shared.log(.system, "AppCoordinator initialization:")
        Logger.shared.log(.system, "  GROK_API_KEY: \(grokApiKey.isEmpty ? "❌ MISSING" : "✓ Present (\(grokApiKey.prefix(10))...)")")
        Logger.shared.log(.system, "  NEBULA_API_KEY: \(nebulaApiKey.isEmpty ? "❌ MISSING" : "✓ Present (\(nebulaApiKey.prefix(10))...)")")
        Logger.shared.log(.system, "  NEBULA_COLLECTION_ID: \(nebulaCollection.isEmpty ? "❌ MISSING" : "✓ Present")")

        let grokClient = GrokClient(apiKey: grokApiKey)
        let nebulaClient = NebulaClient(apiKey: nebulaApiKey, collectionId: nebulaCollection)
        self.grok = grokClient
        self.nebula = nebulaClient
        self.annotator = AnnotatorService(grok: grokClient, capture: captureService)
        self.executor = ExecutorService(grok: grokClient, nebula: nebulaClient)
        self.executionAgent = ExecutionAgent(stateStore: stateStore, overlay: overlay, executor: executor)

        overlay.onAccept = { [weak self] in self?.executeCurrentTask() }
        overlay.onDecline = { [weak self] in
            if let taskId = self?.stateStore.currentTaskId {
                self?.stateStore.decline(taskId: taskId)
            }
        }

        chatOverlay.onSendMessage = { [weak self] message in
            self?.handleChatMessage(message)
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
            self.eventMonitor.onChatToggle = { [weak self] in
                DispatchQueue.main.async {
                    self?.chatOverlay.toggle()
                }
            }
            self.eventMonitor.start()

            self.keystrokeMonitor.onKeyEvent = { [weak self] in
                self?.handleKeystroke()
            }
            self.keystrokeMonitor.start()

            // self.maybeAnnotate(reason: "launch")  // Disabled for testing
            // CONSUMER FLOW: Start the periodic AI processing loop
            self.startAnnotatorLoop()
            
            // CONSUMER A: Start Nebula consumer (stores all annotations)
            self.startNebulaConsumer()
            
            // CONSUMER B: Start Execution Agent consumer (triggers UI for new tasks)
            self.startExecutionAgentConsumer()

            // Initial screen capture on launch (with delay to ensure permissions are processed)
            Logger.shared.log(.capture, "Scheduling initial capture on launch...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                Logger.shared.log(.capture, "Executing initial capture on launch...")
                self?.captureAndBuffer(reason: "launch")
            }
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
        Logger.shared.log(.capture, "🔍 captureAndBuffer called with reason: \(reason)")
        
        // Throttle screen captures to avoid performance hits
        let now = Date()
        if let lastCapture = lastScreenCaptureTime,
           now.timeIntervalSince(lastCapture) < screenCaptureThrottleInterval {
            // Skip this capture, too soon
            Logger.shared.log(.capture, "⏭️ Capture skipped (throttled). Reason: \(reason), lastCapture: \(lastCapture.timeIntervalSinceNow) seconds ago")
            return
        }

        lastScreenCaptureTime = now
        Logger.shared.log(.capture, "🚀 Initiating screen capture. Reason: \(reason)")

        Task { [weak self] in
            guard let self = self else {
                Logger.shared.log(.capture, "❌ Self is nil in capture task")
                return
            }
            Logger.shared.log(.capture, "▶️ Starting async capture task...")
            
            let frame = await self.captureService.captureActiveScreen()
            
            if let frame = frame {
                Logger.shared.log(.capture, "✅ Screen capture succeeded, storing in buffer...")
                await self.contextBuffer.updateLatestScreen(frame)
                Logger.shared.log(.capture, "✅ Screen captured and buffered (\(reason))")
                
                // Debug: Check buffer state after storing
                let stats = await self.contextBuffer.getStats()
                Logger.shared.log(.capture, "📊 Buffer stats after capture: keystrokes=\(stats.keystrokeCount), hasScreen=\(stats.hasScreen)")
            } else {
                Logger.shared.log(.capture, "❌ Screen capture returned nil (\(reason))")
            }
        }
    }

    // MARK: - Consumer Flow (AI Pace)

    /// Start the periodic annotation loop that consumes buffered data
    private func startAnnotatorLoop() {
        Logger.shared.log(.flow, "Consumer loop starting (2s interval)...")

        consumerTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                // Wait for interval (2 seconds for frequent active window capture)
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                Logger.shared.log(.flow, "Loop tick. Checking buffer...")

                // Check if buffer has data
                let stats = await self.contextBuffer.getStats()
                Logger.shared.log(.flow, "📊 Buffer state: keystrokes=\(stats.keystrokeCount), hasScreen=\(stats.hasScreen), lastUpdate=\(stats.lastUpdate?.timeIntervalSinceNow ?? -999)")
                
                let hasData = await self.contextBuffer.hasData()
                guard hasData else {
                    Logger.shared.log(.flow, "❌ Buffer empty, skipping annotation")
                    continue
                }
                
                Logger.shared.log(.flow, "✅ Buffer has data! Proceeding to consume...")

                // Consume buffer
                guard let batch = await self.contextBuffer.consumeAndClear() else {
                    Logger.shared.log(.flow, "Buffer had data but consumeAndClear returned nil")
                    continue
                }

                Logger.shared.log(.flow, "Processing batch: \(batch.keystrokes.count) chars, screen=\(batch.screenFrame != nil)")

                // Process with annotator
                await self.processBufferBatch(batch)
            }

            Logger.shared.log(.flow, "Consumer loop stopped")
        }
    }

    /// Process a consumed buffer batch through the annotator
    private func processBufferBatch(_ batch: BufferBatch) async {
        Logger.shared.log(.flow, "Sending batch to annotator...")

        let result = await self.annotator.annotate(batch: batch)
        switch result {
        case .failure(let error):
            Logger.shared.log(.flow, "Annotation failed: \(error.localizedDescription)")
        case .success(let context):
            // Simply publish to annotation buffer - consumers will handle the rest
            await self.annotationBuffer.publish(context)
        }
    }
    
    // MARK: - Annotation Buffer Consumers
    
    /// Consumer A: Nebula - Stores all annotations to memory
    private func startNebulaConsumer() {
        Logger.shared.log(.stream, "Starting Nebula consumer...")
        
        nebulaConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Subscribe to annotation stream
            let stream = await self.annotationBuffer.makeStream()
            
            // Process each annotation
            for await annotation in stream {
                Logger.shared.log(.nebula, "Nebula consumed event: '\(annotation.taskLabel)'")
                
                // Generate task ID for metadata
                let taskId = self.stableTaskId(for: annotation)
                
                // Build comprehensive content
                var contentParts: [String] = []
                contentParts.append("Task: \(annotation.taskLabel)")
                contentParts.append("App: \(annotation.app)")
                contentParts.append("Window: \(annotation.windowTitle)")
                contentParts.append("\nAnalysis Summary: \(annotation.summary)")
                contentParts.append("Confidence: \(String(format: "%.2f", annotation.confidence))")
                
                let fullContent = contentParts.joined(separator: "\n")
                
                // Comprehensive metadata for semantic search
                let metadata: [String: Any] = [
                    "task_id": taskId,
                    "task_label": annotation.taskLabel,
                    "app": annotation.app,
                    "window_title": annotation.windowTitle,
                    "confidence": annotation.confidence,
                    "timestamp": annotation.timestamp.timeIntervalSince1970,
                    "type": "task_detection"
                ]
                
                Logger.shared.log(.nebula, "Storing context to Nebula: \(fullContent.count) chars")
                
                self.nebula.addMemory(content: fullContent, metadata: metadata) { result in
                    if case .failure(let error) = result {
                        Logger.shared.log(.nebula, "Nebula addMemory error: \(error.localizedDescription)")
                    } else {
                        Logger.shared.log(.nebula, "Context stored successfully for task \(taskId.prefix(8))...")
                    }
                }
            }
            
            Logger.shared.log(.stream, "Nebula consumer stopped")
        }
    }
    
    /// Consumer B: Execution Agent - Determines if automation should be triggered
    private func startExecutionAgentConsumer() {
        Logger.shared.log(.stream, "Starting Execution Agent consumer...")
        
        executionConsumerTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Subscribe to annotation stream
            let stream = await self.annotationBuffer.makeStream()
            
            // Process each annotation
            for await annotation in stream {
                // Delegate to execution agent
                self.executionAgent.processAnnotation(annotation)
            }
            
            Logger.shared.log(.stream, "Execution Agent consumer stopped")
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
                // Pass batch context for comprehensive execution
                self.executor.planAndExecute(task: context, keystrokes: executionBatch.keystrokes) { execResult in
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

    private func pushExecutionResult(taskId: String, plan: String) {
        let metadata: [String: Any] = [
            "task_id": taskId,
            "type": "execution_plan"
        ]
        nebula.addMemory(content: plan, metadata: metadata) { result in
            if case .failure(let error) = result {
                Logger.shared.log(.nebula, "Nebula addMemory (execution) error: \(error.localizedDescription)")
            } else {
                Logger.shared.log(.nebula, "Execution plan stored successfully")
            }
        }
    }

    private func handleChatMessage(_ message: String) {
        chatHistory.append(GrokMessage(role: "user", content: [GrokMessagePart(type: "text", text: message)]))

        let systemPrompt = """
        You are a helpful AI assistant. Be concise and helpful in your responses.
        """

        var messages = [GrokMessage(role: "system", content: [GrokMessagePart(type: "text", text: systemPrompt)])]
        messages.append(contentsOf: chatHistory)

        let request = GrokRequest(model: "grok-2-latest", messages: messages, attachments: nil, stream: false)

        grok.createResponse(request) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self?.chatOverlay.addMessage(role: "assistant", content: "Error: \(error.localizedDescription)")
                case .success(let data):
                    if let response = self?.parseGrokResponse(data) {
                        self?.chatHistory.append(GrokMessage(role: "assistant", content: [GrokMessagePart(type: "text", text: response)]))
                        self?.chatOverlay.addMessage(role: "assistant", content: response)
                    } else {
                        self?.chatOverlay.addMessage(role: "assistant", content: "Failed to parse response")
                    }
                }
            }
        }
    }

    private func parseGrokResponse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Handle x.ai responses format
        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for part in content {
                        if let text = part["text"] as? String {
                            return text
                        }
                    }
                }
            }
        }

        // Fallback: try choices format
        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        return nil
    }
}

