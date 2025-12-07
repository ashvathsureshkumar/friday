//
//  AppCoordinator.swift
//  neb-screen-keys
//

import Cocoa
import CryptoKit

final class AppCoordinator {
    private let stateStore = TaskStateStore()
    private let eventMonitor = EventMonitor()  // Only used for chat toggle
    private let captureService = ScreenCaptureService()
    private let overlay = OverlayController()
    private let chatOverlay = ChatOverlayController()
    private let annotationBuffer = AnnotationBufferService()

    private let annotator: AnnotatorService
    private let executor: ExecutorService
    private let nebula: NebulaClient
    private let grok: GrokClient
    private let executionAgent: ExecutionAgent
    private var chatHistory: [GrokMessage] = []

    // MARK: - State
    private var consumerTask: Task<Void, Never>?

    init(grokApiKey: String = ProcessInfo.processInfo.environment["GROK_API_KEY"] ?? "xai-UzAW09X990AA2mTaseOcfIGJT4TO6D4nfYCIpIZVXljlI4oJeWlkNh5KJjxG4yZt3nZR80CPt6TWirJx",
         nebulaApiKey: String = ProcessInfo.processInfo.environment["NEBULA_API_KEY"] ?? "neb_UNUd5XVnQiPsqWODudTIEg==.dbj0j47j59jKf_eDg6KyBgyS_JIGagKaUfNAziDkkvI=") {

        // Log environment variable status for debugging
        Logger.shared.log(.system, "AppCoordinator initialization:")
        Logger.shared.log(.system, "  GROK_API_KEY: \(grokApiKey.isEmpty ? "❌ MISSING" : "✓ Present (\(grokApiKey.prefix(10))...)")")
        Logger.shared.log(.system, "  NEBULA_API_KEY: \(nebulaApiKey.isEmpty ? "❌ MISSING" : "✓ Present (\(nebulaApiKey.prefix(10))...)")")
        Logger.shared.log(.system, "  NEBULA_COLLECTION_ID: Will be generated dynamically on first use")

        let grokClient = GrokClient(apiKey: grokApiKey)
        // Initialize with a temporary ID - will be replaced when collection is created
        let tempCollectionId = UUID().uuidString
        let nebulaClient = NebulaClient(apiKey: nebulaApiKey, collectionId: tempCollectionId)
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

            // Keep chat toggle functionality
            self.eventMonitor.onChatToggle = { [weak self] in
                DispatchQueue.main.async {
                    self?.chatOverlay.toggle()
                }
            }
            self.eventMonitor.start()

            // Create a new Nebula collection on launch
            // This must complete before starting consumers to ensure collection exists
            self.setupNebulaCollection { [weak self] success in
                guard let self = self else { return }
                if success {
                    Logger.shared.log(.nebula, "✅ Collection ready, starting polling loop...")
                } else {
                    Logger.shared.log(.nebula, "⚠️ Collection setup had issues, but continuing...")
                }
                
                // Start the simple polling loop: capture and annotate every 2 seconds
                self.startPollingLoop()
                
                // CONSUMER A: Start Nebula consumer (stores all annotations)
                self.startNebulaConsumer()
                
                // CONSUMER B: Start Execution Agent consumer (triggers UI for new tasks)
                self.startExecutionAgentConsumer()
            }
        }
    }

    // MARK: - Polling Loop (Simplified)

    /// Simple polling loop: capture screenshot every 2 seconds and send directly to Grok
    private func startPollingLoop() {
        Logger.shared.log(.flow, "Starting polling loop (2s interval)...")

        consumerTask = Task { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                // Wait for interval (2 seconds)
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                Logger.shared.log(.flow, "Polling tick. Capturing screenshot...")

                // Capture screenshot
                let frame = await self.captureService.captureActiveScreen()
                
                guard let frame = frame else {
                    Logger.shared.log(.flow, "⚠️ Screenshot capture failed, skipping this cycle")
                    continue
                }
                
                Logger.shared.log(.flow, "✅ Screenshot captured - App: \(frame.appName), Window: \(frame.windowTitle), Size: \(Int(frame.image.size.width))x\(Int(frame.image.size.height))")
                
                // Create batch with screenshot (no keystrokes needed)
                let batch = BufferBatch(
                    keystrokes: "",
                    screenFrame: frame,
                    ocrText: nil,  // OCR will be extracted in AnnotatorService
                    timestamp: Date()
                )
                
                // Send directly to annotator
                await self.processBatch(batch)
            }

            Logger.shared.log(.flow, "Polling loop stopped")
        }
    }

    /// Process a batch through the annotator
    private func processBatch(_ batch: BufferBatch) async {
        Logger.shared.log(.flow, "Sending screenshot to annotator...")

        let result = await self.annotator.annotate(batch: batch)
        switch result {
        case .failure(let error):
            Logger.shared.log(.flow, "Annotation failed: \(error.localizedDescription)")
        case .success(let context):
            // Publish to annotation buffer - consumers will handle the rest
            await self.annotationBuffer.publish(context)
        }
    }
    
    // MARK: - Annotation Buffer Consumers
    
    /// Consumer A: Nebula - Stores all annotations to memory
    /// Simplified: Uses direct callback instead of AsyncStream
    private func startNebulaConsumer() {
        Logger.shared.log(.stream, "Starting Nebula consumer...")
        
        Task { [weak self] in
            guard let self = self else { return }
            
            // Register handler for Nebula consumer
            await self.annotationBuffer.setNebulaHandler { [weak self] annotation in
                guard let self = self else { return }
                
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
        }
    }
    
    /// Consumer B: Execution Agent - Determines if automation should be triggered
    /// Simplified: Uses direct callback instead of AsyncStream
    private func startExecutionAgentConsumer() {
        Logger.shared.log(.stream, "Starting Execution Agent consumer...")
        
        Task { [weak self] in
            guard let self = self else { return }
            
            // Register handler for Execution Agent consumer
            await self.annotationBuffer.setExecutionHandler { [weak self] annotation in
                guard let self = self else { return }
                // Delegate to execution agent
                self.executionAgent.processAnnotation(annotation)
            }
        }
    }

    private func executeCurrentTask() {
        guard let taskId = stateStore.currentTaskId else { return }
        Logger.shared.log("Execute requested for task \(taskId)")

        // Use stored annotation from ExecutionAgent instead of re-annotating
        guard let context = executionAgent.getCurrentAnnotation() else {
            Logger.shared.log("Execute failed: No annotation context available")
            return
        }

        Logger.shared.log("Using stored annotation: '\(context.taskLabel)'")

        // Execute the task (no keystrokes needed for simplified flow)
        Task { [weak self] in
            guard let self = self else { return }

            self.executor.planAndExecute(task: context, keystrokes: "") { execResult in
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
    
    /// Create a new Nebula collection on app launch
    /// Creates a new collection with a dynamically generated UUID (doesn't delete old collections)
    /// Calls completion when done (true = success, false = had errors but continuing)
    private func setupNebulaCollection(completion: @escaping (Bool) -> Void) {
        Logger.shared.log(.nebula, "Creating new Nebula collection...")
        
        // Generate a unique name with timestamp to avoid conflicts
        let uniqueName = "neb-screen-keys-\(Int(Date().timeIntervalSince1970))"
        
        nebula.createCollection(name: uniqueName) { [weak self] createResult in
            guard let self = self else {
                completion(false)
                return
            }
            
            switch createResult {
            case .success(let newCollectionId):
                Logger.shared.log(.nebula, "✅ New collection created with dynamic ID: \(newCollectionId)")
                self.nebula.setCollectionId(newCollectionId)
                Logger.shared.log(.nebula, "✅ Collection ready for use")
                completion(true)
                
            case .failure(let error):
                let errorString = error.localizedDescription
                Logger.shared.log(.nebula, "❌ Failed to create new collection: \(errorString)")
                
                // If 409 (already exists), try again with different name
                if errorString.contains("409") || errorString.contains("already exists") {
                    Logger.shared.log(.nebula, "🔄 Collection name conflict, retrying with new timestamp...")
                    // Retry once with a slightly different timestamp
                    let retryName = "neb-screen-keys-\(Int(Date().timeIntervalSince1970) + 1)"
                    self.nebula.createCollection(name: retryName) { [weak self] retryResult in
                        guard let self = self else {
                            completion(false)
                            return
                        }
                        switch retryResult {
                        case .success(let newCollectionId):
                            Logger.shared.log(.nebula, "✅ New collection created with dynamic ID: \(newCollectionId)")
                            self.nebula.setCollectionId(newCollectionId)
                            Logger.shared.log(.nebula, "✅ Collection ready for use")
                            completion(true)
                        case .failure:
                            Logger.shared.log(.nebula, "⚠️ Collection creation failed after retry, but continuing anyway")
                            completion(false)
                        }
                    }
                } else {
                    Logger.shared.log(.nebula, "⚠️ Collection creation failed, but continuing anyway")
                    completion(false)
                }
            }
        }
    }
}

