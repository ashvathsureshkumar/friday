//
//  AnnotatorService.swift
//  neb-screen-keys
//

import Cocoa

// MARK: - Chat Completion Response Structures

struct ChatCompletionResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }

    struct Message: Codable {
        let role: String
        let content: String?
    }
}

// MARK: - Annotator Service

final class AnnotatorService {
    private let grok: GrokClient
    private let capture: ScreenCaptureService

    init(grok: GrokClient, capture: ScreenCaptureService) {
        self.grok = grok
        self.capture = capture
    }

    /// Annotate using a BufferBatch (keystrokes + screen frame)
    func annotate(batch: BufferBatch) async -> Result<AnnotatedContext, Error> {
        Logger.shared.log(.annotator, "Annotation request started (keystrokes: \(batch.keystrokes.count) chars)")

        guard let frame = batch.screenFrame else {
            let err = NSError(domain: "annotator", code: -1, userInfo: [NSLocalizedDescriptionKey: "No screen frame in batch"])
            Logger.shared.log(.annotator, "Annotation failed: No screen frame in batch")
            return .failure(err)
        }

        guard let imageData = frame.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: imageData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            let err = NSError(domain: "annotator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode screen image"])
            Logger.shared.log(.annotator, "Annotation failed: Unable to encode screen image")
            return .failure(err)
        }

        Logger.shared.log(.annotator, "Sending request to Grok (image: \(pngData.count / 1024)KB)...")

        let b64 = pngData.base64EncodedString()
        let imageDataUrl = "data:image/png;base64,\(b64)"

        // Build prompt with keystroke context
        let prompt = buildPromptWithKeystrokes(frame: frame, keystrokes: batch.keystrokes)

        // Build OpenAI-compatible chat request with vision
        let request = ChatRequest(
            messages: [
                ChatMessage(role: "user", content: [
                    .text(prompt),
                    .imageUrl(ImageUrl(url: imageDataUrl))
                ])
            ],
            model: "grok-4-fast",  // Fast Grok 4 model
            stream: false,
            temperature: 0.7
        )

        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<AnnotatedContext, Error>, Never>) in
            grok.createResponse(request) { res in
                switch res {
                case .failure(let error):
                    Logger.shared.log(.annotator, "Grok API error: \(error.localizedDescription)")
                    cont.resume(returning: .failure(error))
                case .success(let data):
                    // Log raw response
                    if let responseText = String(data: data, encoding: .utf8) {
                        let truncated = responseText.count > 500 ? String(responseText.prefix(500)) + "..." : responseText
                        Logger.shared.log(.annotator, "Grok raw response (\(responseText.count) chars): \(truncated)")
                    }

                    // Parse Chat Completions response
                    do {
                        let chatResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

                        guard let firstChoice = chatResponse.choices.first,
                              let messageContent = firstChoice.message.content else {
                            let error = NSError(domain: "annotator", code: -3,
                                              userInfo: [NSLocalizedDescriptionKey: "No content in Grok response"])
                            Logger.shared.log(.annotator, "No content in response")
                            cont.resume(returning: .failure(error))
                            return
                        }

                        Logger.shared.log(.annotator, "Extracted content (\(messageContent.count) chars)")

                        // Parse the JSON content from Grok's message
                        guard let parsed = AnnotatorService.parseAnnotated(jsonText: messageContent,
                                                                          fallbackApp: frame.appName,
                                                                          fallbackWindow: frame.windowTitle) else {
                            let error = NSError(domain: "annotator", code: -4,
                                              userInfo: [NSLocalizedDescriptionKey: "Failed to parse AnnotatedContext from Grok content"])
                            Logger.shared.log(.annotator, "Failed to parse AnnotatedContext from content")
                            cont.resume(returning: .failure(error))
                            return
                        }

                        Logger.shared.log(.annotator, "Parsed result: Task='\(parsed.taskLabel)', Confidence=\(parsed.confidence), App=\(parsed.app)")
                        cont.resume(returning: .success(parsed))

                    } catch {
                        Logger.shared.log(.annotator, "JSON decode error: \(error.localizedDescription)")
                        cont.resume(returning: .failure(error))
                    }
                }
            }
        }
        return result
    }

    /// Legacy method - capture screen and annotate (for backward compatibility)
    func annotate() async -> Result<AnnotatedContext, Error> {
        guard let frame = await capture.captureActiveScreen() else {
            let err = NSError(domain: "annotator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to capture screen"])
            return .failure(err)
        }

        // Use the new method with empty keystrokes
        let batch = BufferBatch(keystrokes: "", screenFrame: frame, timestamp: Date())
        return await annotate(batch: batch)
    }

    /// Build the Grok prompt with keystroke context included
    private func buildPromptWithKeystrokes(frame: ScreenFrame, keystrokes: String) -> String {
        let keystrokeSection = keystrokes.isEmpty ? "" : """

        3. **Recent Keystrokes:** \(keystrokes.count) characters of activity detected. This represents user interaction intensity.
        """

        return """
        You are the **Cortex** of an intelligent OS agent. Your capability is **Visual Intent Understanding**.

        **YOUR INPUTS:**
        1. **Active Window Screenshot:** I am sending you a screenshot of ONLY the user's active window (the application they are currently using). No dock, menu bar, or other windows are visible.
        2. **Clean Context:** You are seeing exactly what the user is focused on - the window content without distractions.
        3. **Metadata:** Active App Name (\(frame.appName)), Window Title (\(frame.windowTitle)).\(keystrokeSection)

        **YOUR OBJECTIVE:**
        Analyze the screenshot to produce a structured "AnnotatedContext" JSON object. This data is fed directly into a Swift parser, so the schema must be exact.

        **CRITICAL ANALYSIS RULES:**
        1. **Direct Focus:** You are seeing ONLY what the user is actively working on. This is their exact focus - no background noise.
        2. **OCR Everything:** Read all visible text carefully. Extract specific function names, variable names, error codes (e.g., "Postgres 5432"), email recipients, search queries, etc.
        3. **Detect Friction:** High friction includes: Red error text, "Connection Refused", compile failures, 404 errors, searching for "how to fix..."
        4. **Keystroke Context:** If keystrokes are present, use them to understand what they're typing or editing.
        5. **Window Content Analysis:** Analyze the specific content type:
           - Code editor: Read function names, file paths, errors
           - Browser: Read page titles, URLs, form content
           - Terminal: Read commands and output
           - Email: Read recipients, subject lines
        6. **Strict Output:** Return ONLY raw JSON. Do not use Markdown blocks (```json). Do not add conversational text.

        **OUTPUT SCHEMA:**
        You must respond with ONLY a valid JSON object matching this structure:
        {
        "task_label": "String. Short, specific intent (e.g., 'Debugging Python Error', 'Drafting Email to Investor', 'Reading API Documentation').",
        "confidence": 0.0 to 1.0 (Float). 1.0 = window content is perfectly clear. 0.5 = ambiguous or loading screen.",
        "summary": "String. A detailed sentence describing what the user is doing based on window content. Include specific entities, errors, or actions visible.",
        "app": "String. The confirmed application name.",
        "window_title": "String. The confirmed window title."
        }

        ---

        ### FEW-SHOT EXAMPLES

        #### EXAMPLE 1: The "Blocked Engineer"
        **Input Context:**
        - App: iTerm2
        - Window: "server_logs — zsh"
        - Image: Terminal window showing "CRITICAL ERROR: Connection Refused on Port 5432" in red text. Command history shows `docker-compose up` and restart attempts.

        **GOOD RESPONSE:**
        {
        "task_label": "Debugging Database Connection Error",
        "confidence": 0.95,
        "summary": "User encountered 'Connection Refused on Port 5432' error when running docker-compose. Terminal shows PostgreSQL connection failure. Multiple restart attempts visible in command history.",
        "app": "iTerm2",
        "window_title": "server_logs — zsh"
        }

        **BAD RESPONSE (Too Generic):**
        {
        "task_label": "Using Terminal",
        "confidence": 0.6,
        "summary": "User is working in terminal.",
        "app": "iTerm2",
        "window_title": "server_logs — zsh"
        }

        #### EXAMPLE 2: The "Email Drafter"
        **Input Context:**
        - App: Google Chrome
        - Window: "Compose: Pitch Deck - Gmail"
        - Image: Gmail compose window. Recipient: "john@vc.com". Subject: "Pitch Deck". Body shows "Attached are the financials we discussed in our last meeting..."

        **GOOD RESPONSE:**
        {
        "task_label": "Drafting Email to Investor",
        "confidence": 0.95,
        "summary": "User is composing an email to john@vc.com about 'Pitch Deck' with attached financials. Email references a previous meeting and includes financial documents.",
        "app": "Google Chrome",
        "window_title": "Compose: Pitch Deck - Gmail"
        }

        #### EXAMPLE 3: The "Code Editor"
        **Input Context:**
        - App: Cursor
        - Window: "AppCoordinator.swift"
        - Image: Code editor showing Swift file. Line 33 visible with code: `let grok = GrokClient(apiKey: grokApiKey)`. Cursor blinking on this line.

        **GOOD RESPONSE:**
        {
        "task_label": "Writing API Integration Code",
        "confidence": 0.9,
        "summary": "User is writing GrokClient initialization code in AppCoordinator.swift. Currently editing line 33 where API key is being passed to GrokClient constructor.",
        "app": "Cursor",
        "window_title": "AppCoordinator.swift"
        }
        """
    }

    /// Parse AnnotatedContext from Grok's JSON response
    /// - Returns: AnnotatedContext if parsing succeeds, nil otherwise (NO FAKE SUCCESS)
    private static func parseAnnotated(jsonText: String, fallbackApp: String, fallbackWindow: String) -> AnnotatedContext? {
        let cleaned = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Find JSON object in response
        guard let jsonStart = cleaned.firstIndex(of: "{"),
              let data = String(cleaned[jsonStart...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            Logger.shared.log(.annotator, "Failed to extract JSON object from response")
            return nil
        }

        // Require essential fields
        guard let taskLabel = obj["task_label"] as? String,
              let confidence = obj["confidence"] as? Double,
              let summary = obj["summary"] as? String else {
            Logger.shared.log(.annotator, "Missing required fields (task_label, confidence, or summary)")
            return nil
        }

        let app = (obj["app"] as? String) ?? fallbackApp
        let window = (obj["window_title"] as? String) ?? fallbackWindow

        return AnnotatedContext(
            taskLabel: taskLabel,
            confidence: confidence,
            summary: summary,
            app: app,
            windowTitle: window,
            timestamp: Date()
        )
    }
}

