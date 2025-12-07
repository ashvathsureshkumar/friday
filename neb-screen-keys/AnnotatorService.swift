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
            model: "grok-2-vision-1212",  // Vision-capable model
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
        1. **Current Screen:** A screenshot of the user's macOS desktop.
        2. **Metadata:** Active App Name (\(frame.appName)), Window Title (\(frame.windowTitle)).\(keystrokeSection)

        **YOUR OBJECTIVE:**
        Analyze the screenshot to produce a structured "AnnotatedContext" JSON object. This data is fed directly into a Swift parser, so the schema must be exact.

        **CRITICAL ANALYSIS RULES:**
        1. **Ignore Background Noise:** Focus ONLY on the Active Window defined in the metadata. Ignore background apps.
        2. **OCR & Specificity:** Do not just say "User is coding." Read the text. Extract specific function names, variable names, error codes (e.g., "Postgres 5432"), or email recipients.
        3. **Detect Friction:** High friction includes: Red error text, "Connection Refused", repeatedly refreshing a page, or searching for "how to fix..."
        4. **Keystroke Context:** If keystrokes are present, use them to infer activity intensity. High keystroke count suggests active work, low suggests passive browsing.
        5. **Strict Output:** Return ONLY raw JSON. Do not use Markdown blocks (```json). Do not add conversational text.

        **OUTPUT SCHEMA:**
        You must respond with ONLY a valid JSON object matching this structure:
        {
        "task_label": "String. Short, specific intent (e.g., 'Debugging Python', 'Drafting Email', 'Browsing Documentation').",
        "confidence": 0.0 to 1.0 (Float). 1.0 = text/context is perfectly clear. 0.5 = ambiguous.",
        "summary": "String. A concise, detailed sentence describing the specific content for semantic search. Include key entities found.",
        "app": "String. The confirmed application name.",
        "window_title": "String. The confirmed window title."
        }

        ---

        ### FEW-SHOT EXAMPLES

        #### EXAMPLE 1: The "Blocked Engineer" (Infrastructure Error)
        **Input Context:**
        - App: iTerm2
        - Window: "server_logs — zsh"
        - Image Content: Shows a terminal wall of text with "CRITICAL ERROR: Connection Refused on Port 5432" in red.

        **GOOD RESPONSE:**
        {
        "task_label": "Debugging Infrastructure",
        "confidence": 0.95,
        "summary": "User encountered a 'Connection Refused' error on Port 5432 while deploying. Attempting to restart PostgreSQL.",
        "app": "iTerm2",
        "window_title": "server_logs — zsh"
        }

        **BAD RESPONSE (Vague):**
        {
        "task_label": "Terminal",
        "confidence": 0.5,
        "summary": "User is looking at text in the terminal.",
        "app": "iTerm2",
        "window_title": "server_logs — zsh"
        }

        #### EXAMPLE 2: The "Email Drafter" (Context Aware)
        **Input Context:**
        - App: Google Chrome
        - Window: "Compose: Pitch Deck - Gmail"
        - Image Content: User is typing "Attached are the financials we discussed..."

        **GOOD RESPONSE:**
        {
        "task_label": "Drafting Email",
        "confidence": 0.9,
        "summary": "User is composing an email in Gmail to an investor regarding 'Series A Financials' and the 'Pitch Deck'.",
        "app": "Google Chrome",
        "window_title": "Compose: Pitch Deck - Gmail"
        }

        #### EXAMPLE 3: The "Passive Browser" (Noise Filtering)
        **Input Context:**
        - App: Safari
        - Window: "Hacker News"
        - Image Content: User is scrolling through news headlines.

        **GOOD RESPONSE:**
        {
        "task_label": "Passive Browsing",
        "confidence": 0.8,
        "summary": "User is casually browsing Hacker News headlines. No specific active task detected.",
        "app": "Safari",
        "window_title": "Hacker News"
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

