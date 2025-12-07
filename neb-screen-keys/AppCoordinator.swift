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
    private let spaceMonitor = SpaceMonitor()
    private let mouseMonitor = MouseMonitor()
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
    private var lastSpaceChangeTime: Date?
    private var lastAppSwitchTime: Date?
    private var consumerTask: Task<Void, Never>?
    private var nebulaConsumerTask: Task<Void, Never>?
    private var executionConsumerTask: Task<Void, Never>?

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

            // Space/App change monitor - triggers capture on context switches
            self.spaceMonitor.onChange = { [weak self] reason in
                Logger.shared.log(.event, "Space/app change detected: \(reason)")
                guard let self = self else { return }
                
                // Always capture space changes (they're important context switches)
                // Only deduplicate app_switch if space_change just happened (space_change takes priority)
                let now = Date()
                if reason == "space_change" {
                    self.lastSpaceChangeTime = now
                    // Always capture space changes - they're important
                    self.captureAndBuffer(reason: reason)
                } else if reason == "app_switch" {
                    self.lastAppSwitchTime = now
                    // If space change happened very recently (< 200ms), skip app switch (space change already captured)
                    if let lastSpaceChange = self.lastSpaceChangeTime,
                       now.timeIntervalSince(lastSpaceChange) < 0.2 {
                        Logger.shared.log(.event, "App switch skipped (space change captured recently)")
                        return
                    }
                    // Otherwise, capture the app switch
                    self.captureAndBuffer(reason: reason)
                }
            }
            self.spaceMonitor.start()

            // Mouse click monitor - triggers capture on user clicks
            self.mouseMonitor.onClick = { [weak self] in
                Logger.shared.log(.event, "Mouse click detected")
                self?.captureAndBuffer(reason: "user_click")
            }
            self.mouseMonitor.start()

            // Clear assets folder on launch to prevent screenshot buildup
            self.clearAssetsFolder()

            // Clear Nebula memories on launch FIRST (for demo purposes)
            // This must complete before starting consumers to ensure collection exists
            self.clearNebulaMemories { [weak self] success in
                guard let self = self else { return }
                if success {
                    Logger.shared.log(.nebula, "✅ Collection ready, starting consumers...")
                } else {
                    Logger.shared.log(.nebula, "⚠️ Collection setup had issues, but continuing...")
                }
                
                // CONSUMER FLOW: Start the periodic AI processing loop
                self.startAnnotatorLoop()
                
                // CONSUMER A: Start Nebula consumer (stores all annotations)
                self.startNebulaConsumer()
                
                // CONSUMER B: Start Execution Agent consumer (triggers UI for new tasks)
                self.startExecutionAgentConsumer()
            }

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
        // BUT: Allow space_change and user_click to bypass throttling (they're important user actions)
        let shouldThrottle = reason != "space_change" && reason != "user_click"
        
        let now = Date()
        if shouldThrottle,
           let lastCapture = lastScreenCaptureTime,
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
                
                // Save screenshot for debugging
                self.saveScreenshot(frame.image, reason: reason)
                
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

                // Capture a fresh screenshot before processing (ensures we always have latest screen state)
                Logger.shared.log(.flow, "📸 Capturing fresh screenshot for annotation...")
                let freshFrame = await self.captureService.captureActiveScreen()
                if let frame = freshFrame {
                    await self.contextBuffer.updateLatestScreen(frame)
                    Logger.shared.log(.flow, "✅ Fresh screenshot captured and buffered")
                } else {
                    Logger.shared.log(.flow, "⚠️ Fresh capture failed, using buffered frame")
                }

                // Consume buffer (now with fresh screenshot)
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
        
        // Save screenshot to assets for every annotation (debugging)
        if let frame = batch.screenFrame {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
            let timestamp = formatter.string(from: batch.timestamp)
            let reason = "annotation_\(timestamp)"
            self.saveScreenshot(frame.image, reason: reason)
        }

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

        // Use stored annotation from ExecutionAgent instead of re-annotating
        guard let context = executionAgent.getCurrentAnnotation() else {
            Logger.shared.log("Execute failed: No annotation context available")
            return
        }

        Logger.shared.log("Using stored annotation: '\(context.taskLabel)'")

        // Get any recent keystrokes from buffer (optional, for additional context)
        Task { [weak self] in
            guard let self = self else { return }
            let batch = await self.contextBuffer.consumeAndClear()
            let keystrokes = batch?.keystrokes ?? ""

            self.executor.planAndExecute(task: context, keystrokes: keystrokes) { execResult in
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
    
    // MARK: - Debug Helpers
    
    /// Clear the assets folder to prevent screenshot buildup
    private func clearAssetsFolder() {
        let projectRoot = "/Users/vagminviswanathan/Desktop/happyNebula/friday"
        let assetsURL = URL(fileURLWithPath: projectRoot).appendingPathComponent("assets")
        
        guard FileManager.default.fileExists(atPath: assetsURL.path) else {
            Logger.shared.log(.capture, "📁 Assets folder doesn't exist, skipping clear")
            return
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil, options: [])
            var deletedCount = 0
            for fileURL in contents {
                try FileManager.default.removeItem(at: fileURL)
                deletedCount += 1
            }
            Logger.shared.log(.capture, "🧹 Cleared assets folder: deleted \(deletedCount) file(s)")
        } catch {
            Logger.shared.log(.capture, "⚠️ Failed to clear assets folder: \(error.localizedDescription)")
        }
    }
    
    /// Save screenshot to desktop folder and assets folder for debugging
    private func saveScreenshot(_ image: NSImage, reason: String) {
        Task {
            // Generate filename with timestamp
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let timestamp = formatter.string(from: Date())
            let filename = "capture_\(timestamp)_\(reason).png"
            
            // Convert NSImage to PNG data
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                Logger.shared.log(.capture, "❌ Failed to convert image to PNG for saving")
                return
            }
            
            // Save to desktop (backward compatibility)
            let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
            let desktopFolderURL = desktopURL.appendingPathComponent("neb-screen-captures")
            try? FileManager.default.createDirectory(at: desktopFolderURL, withIntermediateDirectories: true)
            let desktopFileURL = desktopFolderURL.appendingPathComponent(filename)
            
            do {
                try pngData.write(to: desktopFileURL)
                Logger.shared.log(.capture, "💾 Screenshot saved to desktop: \(desktopFileURL.path)")
            } catch {
                Logger.shared.log(.capture, "❌ Failed to save screenshot to desktop: \(error.localizedDescription)")
            }
            
            // Save to assets folder (project root)
            let projectRoot = "/Users/vagminviswanathan/Desktop/happyNebula/friday"
            let assetsURL = URL(fileURLWithPath: projectRoot).appendingPathComponent("assets")
            try? FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
            let assetsFileURL = assetsURL.appendingPathComponent(filename)
            
            do {
                try pngData.write(to: assetsFileURL)
                Logger.shared.log(.capture, "💾 Screenshot saved to assets: \(assetsFileURL.path)")
            } catch {
                Logger.shared.log(.capture, "❌ Failed to save screenshot to assets: \(error.localizedDescription)")
            }
        }
    }
    
    /// Clear all Nebula memories on app launch by deleting and recreating the collection
    /// Creates a new collection with a dynamically generated UUID
    /// Calls completion when done (true = success, false = had errors but continuing)
    private func clearNebulaMemories(completion: @escaping (Bool) -> Void) {
        Logger.shared.log(.nebula, "🧹 Clearing all Nebula memories for demo (deleting and recreating collection)...")
        
        // Helper function to create a new collection with retry logic
        func createNewCollection(retryCount: Int = 0) {
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
                    
                    // If 409 (already exists) and we haven't retried, try again with different name
                    if errorString.contains("409") || errorString.contains("already exists") {
                        if retryCount < 3 {
                            Logger.shared.log(.nebula, "🔄 Retrying collection creation (attempt \(retryCount + 1))...")
                            createNewCollection(retryCount: retryCount + 1)
                        } else {
                            Logger.shared.log(.nebula, "⚠️ Max retries reached, continuing with existing collection ID")
                            completion(false)
                        }
                    } else {
                        Logger.shared.log(.nebula, "⚠️ Collection creation failed, but continuing anyway")
                        completion(false)
                    }
                }
            }
        }
        
        // Try to delete existing collection first
        nebula.deleteCollection { [weak self] deleteResult in
            guard let self = self else {
                completion(false)
                return
            }
            
            switch deleteResult {
            case .success:
                Logger.shared.log(.nebula, "✅ Collection deleted successfully")
                // Wait a bit before creating new one to ensure deletion is processed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    createNewCollection()
                }
                
            case .failure(let error):
                // If deletion failed (404 = doesn't exist, or other error), create a new one anyway
                let errorString = error.localizedDescription
                if errorString.contains("404") || errorString.contains("Not Found") {
                    Logger.shared.log(.nebula, "ℹ️ Collection doesn't exist (expected on first run)")
                } else {
                    Logger.shared.log(.nebula, "⚠️ Collection deletion result: \(errorString)")
                }
                Logger.shared.log(.nebula, "Creating new collection...")
                createNewCollection()
            }
        }
    }
}

