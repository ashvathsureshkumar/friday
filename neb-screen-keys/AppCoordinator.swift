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
    private let voiceActivation = VoiceActivationService()
    private let welcomeAnimation = WelcomeAnimationController()

    private let annotator: AnnotatorService
    private let executor: ExecutorService
    private let nebula: NebulaClient
    private let grok: GrokClient
    private let executionAgent: ExecutionAgent
    private static let nebulaCollectionDefaultsKey = "NebulaCollectionID"
    private let providedNebulaCollectionId: String?
    private var chatHistory: [GrokMessage] = []

    // MARK: - State
    private var consumerTask: Task<Void, Never>?
    private var pendingAppleScript: String?
    private var isActivated = false  // Track if voice activation has occurred

    init(grokApiKey: String = ProcessInfo.processInfo.environment["GROK_API_KEY"] ?? "xai-UzAW09X990AA2mTaseOcfIGJT4TO6D4nfYCIpIZVXljlI4oJeWlkNh5KJjxG4yZt3nZR80CPt6TWirJx",
         nebulaApiKey: String = ProcessInfo.processInfo.environment["NEBULA_API_KEY"] ?? "neb_UNUd5XVnQiPsqWODudTIEg==.dbj0j47j59jKf_eDg6KyBgyS_JIGagKaUfNAziDkkvI=") {

        let trimmedCollectionId = ProcessInfo.processInfo.environment["NEBULA_COLLECTION_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let providedCollectionId = (trimmedCollectionId?.isEmpty == false) ? trimmedCollectionId : nil
        let persistedCollectionId = UserDefaults.standard.string(forKey: AppCoordinator.nebulaCollectionDefaultsKey)
        let initialCollectionId = providedCollectionId ?? persistedCollectionId ?? UUID().uuidString

        // Log environment variable status for debugging
        Logger.shared.log(.system, "AppCoordinator initialization:")
        Logger.shared.log(.system, "  GROK_API_KEY: \(grokApiKey.isEmpty ? "❌ MISSING" : "✓ Present (\(grokApiKey.prefix(10))...)")")
        Logger.shared.log(.system, "  NEBULA_API_KEY: \(nebulaApiKey.isEmpty ? "❌ MISSING" : "✓ Present (\(nebulaApiKey.prefix(10))...)")")
        if let providedCollectionId {
            Logger.shared.log(.system, "  NEBULA_COLLECTION_ID: ✓ Provided (\(providedCollectionId.prefix(10))...)")
        } else if let persistedCollectionId {
            Logger.shared.log(.system, "  NEBULA_COLLECTION_ID: ✓ Persisted (\(persistedCollectionId.prefix(10))...)")
        } else {
            Logger.shared.log(.system, "  NEBULA_COLLECTION_ID: ⚠️ Not provided; will create and persist")
        }

        let grokClient = GrokClient(apiKey: grokApiKey)
        self.providedNebulaCollectionId = providedCollectionId
        let nebulaClient = NebulaClient(apiKey: nebulaApiKey, collectionId: initialCollectionId)
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

        chatOverlay.onExecuteScript = { [weak self] in
            self?.executePendingScript()
        }

        chatOverlay.onCancelScript = { [weak self] in
            self?.cancelPendingScript()
        }

        chatOverlay.onChatOpened = { [weak self] in
            self?.sendProactiveGreeting()
        }
        
        // Setup voice activation callback
        voiceActivation.onWakeWordDetected = { [weak self] in
            self?.handleWakeWordDetected()
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

            // Keep chat toggle functionality (but only works after activation)
            self.eventMonitor.onChatToggle = { [weak self] in
                guard let self = self, self.isActivated else { return }
                DispatchQueue.main.async {
                    self.chatOverlay.toggle()
                }
            }
            self.eventMonitor.start()

            // Request speech recognition permissions and start voice activation
            self.voiceActivation.requestPermissions { [weak self] granted in
                guard let self = self else { return }
                if granted {
                    Logger.shared.log(.system, "🎤 Starting voice activation - waiting for 'daddy's home'...")
                    self.voiceActivation.startListening()
                } else {
                    Logger.shared.log(.system, "❌ Speech recognition not authorized - starting normally")
                    self.startNormalWorkflow()
                }
            }
        }
    }
    
    // MARK: - Voice Activation
    
    private func handleWakeWordDetected() {
        guard !isActivated else {
            Logger.shared.log(.system, "⚠️ Already activated, ignoring wake word")
            return
        }
        
        Logger.shared.log(.system, "🎉 Wake word detected! Showing welcome animation...")
        
        // Show welcome animation
        welcomeAnimation.show { [weak self] in
            guard let self = self else { return }
            Logger.shared.log(.system, "✅ Welcome animation complete - starting normal workflow")
            self.startNormalWorkflow()
        }
    }
    
    private func startNormalWorkflow() {
        guard !isActivated else { return }
        isActivated = true
        
        Logger.shared.log(.system, "🚀 Starting F.R.I.D.A.Y. normal workflow...")
        
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

    private func debugLog(_ text: String) {
        let logFile = "/tmp/neb-chat-debug.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(text)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile) {
                if let handle = FileHandle(forWritingAtPath: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logFile, contents: data, attributes: nil)
            }
        }
    }

    private func sendProactiveGreeting() {
        debugLog("sendProactiveGreeting called")

        // Reset chat history for fresh conversation
        chatHistory.removeAll()

        // Use detached task to avoid MainActor deadlock with screen capture
        Task.detached { [weak self] in
            guard let self = self else { return }

            // Capture full screen in background
            await MainActor.run { self.debugLog("Capturing full screen for greeting...") }
            let frame = await self.captureService.captureFullScreen()
            await MainActor.run { self.debugLog("Full screen capture done: \(frame != nil ? "success" : "nil")") }

            // Build proactive message with screen context
            var userContent: [GrokMessagePart] = [
                GrokMessagePart(type: "text", text: "The user just opened the chat. Look at their screen and give a brief, helpful greeting that acknowledges what they're working on. Offer to help with something relevant to what you see. Keep it concise (1-2 sentences).")
            ]

            // Add screen image if available
            if let frame = frame,
               let tiffData = frame.image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                let base64 = pngData.base64EncodedString()
                let imageUrl = ImageUrl(url: "data:image/png;base64,\(base64)")
                userContent.append(GrokMessagePart(type: "image_url", text: nil, imageUrl: imageUrl))
                await MainActor.run { self.debugLog("Added screen capture to greeting request") }
            }

            await MainActor.run {
                self.debugLog("Sending proactive greeting request to Grok...")

                let systemPrompt = """
                You are a helpful AI desktop assistant. You can see the user's screen.
                Be concise and helpful. Acknowledge what the user is currently working on based on what you see.
                Offer relevant assistance based on their current context.

                AUTOMATION CAPABILITY:
                If the user asks you to DO something (run a command, type text, click something, automate a task),
                you can generate AppleScript to perform the action. When generating automation:
                1. First explain briefly what the script will do
                2. Include the AppleScript in a ```applescript code block
                3. Tell the user to press Cmd+Y to execute or Cmd+N to cancel

                Only generate AppleScript when the user explicitly asks you to DO something.
                For questions or explanations, just respond normally without scripts.
                """

                var messages = [GrokMessage(role: "system", content: [GrokMessagePart(type: "text", text: systemPrompt)])]
                messages.append(GrokMessage(role: "user", content: userContent))

                // Use grok-4-1-fast-non-reasoning for fast multimodal responses
                let request = GrokRequest(model: "grok-4-1-fast-non-reasoning", messages: messages, attachments: nil, stream: false)

                self.grok.createResponse(request) { [weak self] result in
                    DispatchQueue.main.async {
                        switch result {
                        case .failure(let error):
                            self?.debugLog("Greeting API error: \(error.localizedDescription)")
                            self?.chatOverlay.addMessage(role: "assistant", content: "Hi! How can I help you?")
                            self?.chatOverlay.enableInput()  // Show input after greeting
                        case .success(let data):
                            self?.debugLog("Greeting response received: \(data.count) bytes")
                            if let response = self?.parseGrokResponse(data) {
                                self?.debugLog("Greeting parsed: \(response.prefix(100))")
                                self?.chatHistory.append(GrokMessage(role: "assistant", content: [GrokMessagePart(type: "text", text: response)]))
                                self?.chatOverlay.addMessage(role: "assistant", content: response)
                            } else {
                                self?.debugLog("Greeting parse failed")
                                self?.chatOverlay.addMessage(role: "assistant", content: "Hi! How can I help you?")
                            }
                            self?.chatOverlay.enableInput()  // Show input after greeting
                        }
                    }
                }
            }
        }
    }

    private func handleChatMessage(_ message: String) {
        debugLog("handleChatMessage called with: \(message)")

        // Show "Thinking..." and pause inactivity timer
        chatOverlay.setWaitingForResponse(true)

        // Use detached task to avoid MainActor deadlock with screen capture
        Task.detached { [weak self] in
            guard let self = self else { return }

            // Run screen capture and Nebula search in parallel
            await MainActor.run { self.debugLog("Starting parallel: screen capture + Nebula search...") }

            // Start both operations concurrently
            async let screenCaptureTask = self.captureService.captureFullScreen()
            async let nebulaSearchTask = self.searchNebulaAsync(query: message)

            // Wait for both to complete
            let frame = await screenCaptureTask
            let memoryContext = await nebulaSearchTask

            await MainActor.run {
                self.debugLog("Parallel ops done: screen=\(frame != nil ? "success" : "nil"), memories=\(memoryContext.count) chars")
            }

            // Build user message with optional image
            var userContent: [GrokMessagePart] = [GrokMessagePart(type: "text", text: message)]

            // Add screen image if available
            if let frame = frame,
               let tiffData = frame.image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                let base64 = pngData.base64EncodedString()
                let imageUrl = ImageUrl(url: "data:image/png;base64,\(base64)")
                userContent.append(GrokMessagePart(type: "image_url", text: nil, imageUrl: imageUrl))
                await MainActor.run { self.debugLog("Added screen capture to message") }
            }

            await MainActor.run { self.debugLog("About to run on MainActor...") }
            await MainActor.run {
                self.debugLog("Inside MainActor.run")
                self.chatHistory.append(GrokMessage(role: "user", content: userContent))

                // Build memory context section for system prompt
                let memorySection = memoryContext.isEmpty ? "" : """

                RETRIEVED MEMORIES (context from past interactions):
                \(memoryContext)

                Use this context to personalize your responses and remember past interactions with the user.
                """

                let systemPrompt = """
                You are a helpful AI desktop assistant. You can see the user's screen.
                Be concise and helpful. If the user asks about what's on screen, describe what you see.
                Help them with tasks related to what they're working on.
                \(memorySection)
                MEMORY TOOL:
                You have access to a memory search tool called "search_memories". Use it when you need
                to search for MORE SPECIFIC information beyond what's already provided in RETRIEVED MEMORIES above.

                AUTOMATION CAPABILITY:
                If the user asks you to DO something (run a command, type text, click something, automate a task),
                you can generate AppleScript to perform the action. When generating automation:
                1. First explain briefly what the script will do
                2. Include the AppleScript in a ```applescript code block
                3. Tell the user to press Cmd+Y to execute or Cmd+N to cancel

                Example automation response:
                "I'll type that command in Terminal for you.

                ```applescript
                tell application "Terminal"
                    activate
                end tell
                delay 0.3
                tell application "System Events"
                    keystroke "ls -la"
                    keystroke return
                end tell
                ```

                Press Cmd+Y to execute or Cmd+N to cancel."

                Only generate AppleScript when the user explicitly asks you to DO something.
                For questions or explanations, just respond normally without scripts.
                """

                var messages = [GrokMessage(role: "system", content: [GrokMessagePart(type: "text", text: systemPrompt)])]
                messages.append(contentsOf: self.chatHistory)

                // Define the search_memories tool
                let searchMemoriesTool = GrokTool(
                    type: "function",
                    function: GrokFunction(
                        name: "search_memories",
                        description: "Search past memories and context for relevant information. Use this when the user asks about past events, previous discussions, or needs historical context.",
                        parameters: GrokFunctionParameters(
                            type: "object",
                            properties: [
                                "query": GrokPropertyDefinition(
                                    type: "string",
                                    description: "The search query to find relevant memories"
                                )
                            ],
                            required: ["query"]
                        )
                    )
                )

                // Use grok-4-1-fast-non-reasoning for fast multimodal responses with tools
                let request = GrokRequest(
                    model: "grok-4-1-fast-non-reasoning",
                    messages: messages,
                    attachments: nil,
                    stream: false,
                    tools: [searchMemoriesTool],
                    toolChoice: "auto"
                )

                self.debugLog("Sending to Grok API with screen context and tools...")
                self.sendChatRequest(request: request, messages: messages)
            }
        }
    }

    /// Send chat request and handle tool calls recursively
    private func sendChatRequest(request: GrokRequest, messages: [GrokMessage]) {
        grok.createResponse(request) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self?.debugLog("API error: \(error.localizedDescription)")
                    self?.chatOverlay.addMessage(role: "assistant", content: "Error: \(error.localizedDescription)")
                case .success(let data):
                    self?.debugLog("Response received: \(data.count) bytes")
                    if let rawResponse = String(data: data, encoding: .utf8) {
                        self?.debugLog("Raw response: \(rawResponse.prefix(500))")
                    }

                    // Try to parse as tool call response first
                    if let toolCallResponse = self?.parseToolCallResponse(data) {
                        self?.debugLog("Detected tool call: \(toolCallResponse.name)")
                        self?.handleToolCall(toolCallResponse, originalMessages: messages, request: request)
                    } else if let response = self?.parseGrokResponse(data) {
                        // Normal text response
                        self?.debugLog("Parsed OK: \(response.prefix(100))")
                        self?.chatHistory.append(GrokMessage(role: "assistant", content: [GrokMessagePart(type: "text", text: response)]))

                        // Check for AppleScript and store it for execution
                        if let script = self?.extractAppleScript(from: response) {
                            self?.pendingAppleScript = script
                            self?.debugLog("Detected AppleScript, stored for execution")
                            self?.chatOverlay.showScriptPending(true)
                        } else {
                            self?.pendingAppleScript = nil
                            self?.chatOverlay.showScriptPending(false)
                        }

                        self?.chatOverlay.addMessage(role: "assistant", content: response)
                    } else {
                        self?.debugLog("Parse FAILED - calling addMessage with error")
                        self?.chatOverlay.addMessage(role: "assistant", content: "Failed to parse response")
                    }
                }
            }
        }
    }

    /// Parse tool call from Grok response
    private func parseToolCallResponse(_ data: Data) -> (id: String, name: String, arguments: [String: Any])? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]],
              let toolCall = toolCalls.first,
              let id = toolCall["id"] as? String,
              let function = toolCall["function"] as? [String: Any],
              let name = function["name"] as? String,
              let argumentsString = function["arguments"] as? String,
              let argumentsData = argumentsString.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
            return nil
        }
        return (id: id, name: name, arguments: arguments)
    }

    /// Handle tool call by executing the tool and sending results back
    private func handleToolCall(_ toolCall: (id: String, name: String, arguments: [String: Any]), originalMessages: [GrokMessage], request: GrokRequest) {
        debugLog("Handling tool call: \(toolCall.name) with args: \(toolCall.arguments)")

        switch toolCall.name {
        case "search_memories":
            guard let query = toolCall.arguments["query"] as? String else {
                debugLog("Missing query argument for search_memories")
                chatOverlay.addMessage(role: "assistant", content: "Error: Could not parse memory search query")
                return
            }

            debugLog("Searching Nebula for: \(query)")
            nebula.searchMemories(query: query, limit: 5) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }

                    var toolResultContent: String
                    switch result {
                    case .failure(let error):
                        self.debugLog("Nebula search failed: \(error.localizedDescription)")
                        toolResultContent = "Memory search failed: \(error.localizedDescription)"
                    case .success(let data):
                        // Parse Nebula search results
                        if let results = self.parseNebulaSearchResults(data) {
                            if results.isEmpty {
                                toolResultContent = "No relevant memories found."
                            } else {
                                toolResultContent = "Found \(results.count) relevant memories:\n\n" + results.joined(separator: "\n\n---\n\n")
                            }
                            self.debugLog("Nebula returned \(results.count) results")
                        } else {
                            toolResultContent = "No relevant memories found."
                            self.debugLog("Could not parse Nebula response")
                        }
                    }

                    // Build follow-up request with tool result
                    // Need to include the assistant's tool call message and our tool response
                    var newMessages = originalMessages

                    // Add the assistant message that made the tool call
                    // Must include the tool_calls array for the API to understand context
                    let assistantToolCallMsg = GrokMessage(
                        role: "assistant",
                        content: nil,  // Content is null when making tool calls
                        toolCalls: [
                            GrokToolCall(
                                id: toolCall.id,
                                type: "function",
                                function: GrokToolCallFunction(
                                    name: toolCall.name,
                                    arguments: String(data: try! JSONSerialization.data(withJSONObject: toolCall.arguments), encoding: .utf8) ?? "{}"
                                )
                            )
                        ]
                    )
                    newMessages.append(assistantToolCallMsg)

                    // Add the tool result message with the tool_call_id
                    let toolResultMsg = GrokMessage(
                        role: "tool",
                        content: [GrokMessagePart(type: "text", text: toolResultContent)],
                        toolCallId: toolCall.id
                    )
                    newMessages.append(toolResultMsg)

                    // Send follow-up request without tools to get final response
                    let followUpRequest = GrokRequest(
                        model: request.model,
                        messages: newMessages,
                        attachments: nil,
                        stream: false,
                        tools: nil,  // No tools for follow-up
                        toolChoice: nil
                    )

                    self.debugLog("Sending follow-up request with tool results...")
                    self.sendChatRequest(request: followUpRequest, messages: newMessages)
                }
            }

        default:
            debugLog("Unknown tool: \(toolCall.name)")
            chatOverlay.addMessage(role: "assistant", content: "Error: Unknown tool '\(toolCall.name)'")
        }
    }

    /// Parse Nebula search results into readable strings
    private func parseNebulaSearchResults(_ data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Try different response formats
        var results: [[String: Any]]?

        if let r = json["results"] as? [[String: Any]] {
            results = r
        } else if let memories = json["memories"] as? [[String: Any]] {
            results = memories
        } else if let data = json["data"] as? [[String: Any]] {
            results = data
        }

        guard let memories = results else {
            return []
        }

        return memories.compactMap { memory -> String? in
            let content = memory["content"] as? String ?? memory["raw_text"] as? String ?? ""
            let metadata = memory["metadata"] as? [String: Any] ?? [:]
            let taskLabel = metadata["task_label"] as? String ?? ""
            let app = metadata["app"] as? String ?? ""

            if content.isEmpty { return nil }

            var result = content
            if !taskLabel.isEmpty || !app.isEmpty {
                result = "[\(taskLabel) - \(app)]\n\(content)"
            }
            return result
        }
    }

    /// Async wrapper for Nebula search - returns formatted memory context string
    private func searchNebulaAsync(query: String) async -> String {
        await withCheckedContinuation { continuation in
            nebula.searchMemories(query: query, limit: 5) { [weak self] result in
                switch result {
                case .failure(let error):
                    // 404 errors are expected when collection is new/empty - just return empty
                    let errorStr = error.localizedDescription
                    if errorStr.contains("Not Found") || errorStr.contains("404") {
                        Logger.shared.log(.nebula, "Upfront search: collection empty or not ready")
                    } else {
                        Logger.shared.log(.nebula, "Upfront search failed: \(errorStr)")
                    }
                    continuation.resume(returning: "")
                case .success(let data):
                    if let results = self?.parseNebulaSearchResults(data), !results.isEmpty {
                        let context = results.joined(separator: "\n\n---\n\n")
                        Logger.shared.log(.nebula, "Upfront search: found \(results.count) memories")
                        continuation.resume(returning: context)
                    } else {
                        Logger.shared.log(.nebula, "Upfront search: no results")
                        continuation.resume(returning: "")
                    }
                }
            }
        }
    }

    private func extractAppleScript(from text: String) -> String? {
        guard let startRange = text.range(of: "```applescript"),
              let endRange = text.range(of: "```", range: startRange.upperBound..<text.endIndex) else {
            return nil
        }
        let script = String(text[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return script.isEmpty ? nil : script
    }

    private func executePendingScript() {
        guard let script = pendingAppleScript else {
            debugLog("No pending script to execute")
            return
        }

        debugLog("Executing pending AppleScript...")
        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorDict)

        if let errorDict = errorDict {
            debugLog("AppleScript execution error: \(errorDict)")
            chatOverlay.addMessage(role: "assistant", content: "Script execution failed: \(errorDict)")
        } else if let result = result {
            debugLog("AppleScript executed successfully: \(result.stringValue ?? "no return value")")
            chatOverlay.addMessage(role: "assistant", content: "Done!")
        } else {
            debugLog("AppleScript executed (no return value)")
            chatOverlay.addMessage(role: "assistant", content: "Done!")
        }

        pendingAppleScript = nil
        chatOverlay.showScriptPending(false)
    }

    private func cancelPendingScript() {
        debugLog("Cancelled pending script")
        pendingAppleScript = nil
        chatOverlay.showScriptPending(false)
        chatOverlay.addMessage(role: "assistant", content: "Cancelled.")
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

