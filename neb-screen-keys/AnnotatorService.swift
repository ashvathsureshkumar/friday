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
        let request = GrokRequest(
            model: "grok-4-fast",  // Fast Grok 4 model
            messages: [
                GrokMessage(role: "user", content: [
                    GrokMessagePart(type: "text", text: prompt),
                    GrokMessagePart(type: "image_url", imageUrl: ImageUrl(url: imageDataUrl))
                ])
            ],
            attachments: nil,
            stream: false
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
        "activity_type": "String. One of: 'blocked', 'help_seeking', 'tedious', 'passive', 'meeting', 'productive'. You MUST pick one - see definitions below.",
        "popup_style": "String. One of: 'cursor', 'notification'. See definitions below.",
        "app": "String. The confirmed application name.",
        "window_title": "String. The confirmed window title."
        }

        **ACTIVITY TYPE DEFINITIONS (you MUST choose exactly one - no "ambiguous" or "unknown"):**
        - **blocked**: User is STUCK. Errors visible, build failures, connection refused, exceptions, crash logs, red error text.
        - **help_seeking**: User is SEARCHING for solutions. Stack Overflow, googling error messages, reading GitHub issues, "how to fix" searches.
        - **tedious**: User doing REPETITIVE work that automation could speed up. Formatting code, copy-pasting between apps, running same commands.
        - **passive**: User is READING or CONSUMING content. Documentation, articles, watching videos, casual browsing, social media. Also use for loading screens or unclear contexts.
        - **meeting**: User is in a VIDEO CALL or screen sharing. Zoom, Teams, Meet, FaceTime visible.
        - **productive**: User is IN FLOW. Actively typing code, writing content, making progress. Do NOT interrupt.

        **POPUP STYLE DEFINITIONS:**
        - **cursor**: Use when the action is CONTEXTUAL to cursor position. Examples: type a command in terminal at cursor, click a specific button, paste text at insertion point, edit code at current line.
        - **notification**: Use when the action is APP-WIDE or GENERAL. Examples: format entire file, run build command, open new tab/window, switch applications, search Stack Overflow.

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
        "activity_type": "blocked",
        "popup_style": "cursor",
        "app": "iTerm2",
        "window_title": "server_logs — zsh"
        }
        (popup_style is "cursor" because fix command should be typed at terminal cursor)

        **BAD RESPONSE (Too Generic):**
        {
        "task_label": "Using Terminal",
        "confidence": 0.6,
        "summary": "User is working in terminal.",
        "activity_type": "productive",
        "popup_style": "notification",
        "app": "iTerm2",
        "window_title": "server_logs — zsh"
        }
        (This is bad because it missed the error - should be "blocked" with higher confidence)

        #### EXAMPLE 2: The "Email Drafter" (productive)
        **Input Context:**
        - App: Google Chrome
        - Window: "Compose: Pitch Deck - Gmail"
        - Image: Gmail compose window. Recipient: "john@vc.com". Subject: "Pitch Deck". Body shows "Attached are the financials we discussed in our last meeting..."

        **GOOD RESPONSE:**
        {
        "task_label": "Drafting Email to Investor",
        "confidence": 0.95,
        "summary": "User is composing an email to john@vc.com about 'Pitch Deck' with attached financials. Email references a previous meeting and includes financial documents.",
        "activity_type": "productive",
        "popup_style": "cursor",
        "app": "Google Chrome",
        "window_title": "Compose: Pitch Deck - Gmail"
        }

        #### EXAMPLE 3: The "Code Editor" (productive)
        **Input Context:**
        - App: Cursor
        - Window: "AppCoordinator.swift"
        - Image: Code editor showing Swift file. Line 33 visible with code: `let grok = GrokClient(apiKey: grokApiKey)`. Cursor blinking on this line.

        **GOOD RESPONSE:**
        {
        "task_label": "Writing API Integration Code",
        "confidence": 0.9,
        "summary": "User is writing GrokClient initialization code in AppCoordinator.swift. Currently editing line 33 where API key is being passed to GrokClient constructor.",
        "activity_type": "productive",
        "popup_style": "cursor",
        "app": "Cursor",
        "window_title": "AppCoordinator.swift"
        }

        #### EXAMPLE 4: The "Help Seeker"
        **Input Context:**
        - App: Arc
        - Window: "python TypeError: 'NoneType' - Stack Overflow"
        - Image: Browser showing Stack Overflow question about TypeError. User has searched for an error they encountered.

        **GOOD RESPONSE:**
        {
        "task_label": "Researching Python TypeError",
        "confidence": 0.9,
        "summary": "User is searching Stack Overflow for help with a Python TypeError: 'NoneType' error. They are looking for solutions to a bug they encountered.",
        "activity_type": "help_seeking",
        "popup_style": "notification",
        "app": "Arc",
        "window_title": "python TypeError: 'NoneType' - Stack Overflow"
        }
        (popup_style is "notification" because action would be to copy solution and paste elsewhere, not cursor-specific)

        #### EXAMPLE 5: The "Passive Reader"
        **Input Context:**
        - App: Safari
        - Window: "Introduction | React Documentation"
        - Image: React documentation page showing introductory tutorial content. No errors or searches visible.

        **GOOD RESPONSE:**
        {
        "task_label": "Reading React Documentation",
        "confidence": 0.85,
        "summary": "User is reading the React documentation introduction page. They appear to be learning or reviewing React concepts.",
        "activity_type": "passive",
        "popup_style": "notification",
        "app": "Safari",
        "window_title": "Introduction | React Documentation"
        }

        #### EXAMPLE 6: The "Meeting Attendee"
        **Input Context:**
        - App: zoom.us
        - Window: "Zoom Meeting"
        - Image: Zoom video call with multiple participants visible in gallery view.

        **GOOD RESPONSE:**
        {
        "task_label": "Attending Video Meeting",
        "confidence": 0.95,
        "summary": "User is in a Zoom video call with multiple participants. This is an active meeting.",
        "activity_type": "meeting",
        "popup_style": "notification",
        "app": "zoom.us",
        "window_title": "Zoom Meeting"
        }

        #### EXAMPLE 7: The "Copy-Paste Workflow" (tedious)
        **Input Context:**
        - App: Cursor
        - Window: "data.json"
        - Image: Code editor with JSON file. User appears to be copying field names between files.

        **GOOD RESPONSE:**
        {
        "task_label": "Copy-Paste Data Fields",
        "confidence": 0.8,
        "summary": "User is copying field names from a JSON file, likely to paste into another location. Repetitive copy-paste workflow detected.",
        "activity_type": "tedious",
        "popup_style": "cursor",
        "app": "Cursor",
        "window_title": "data.json"
        }
        (popup_style is "cursor" because paste operation happens at cursor location)
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

        // Parse activity_type (default to passive if missing)
        let activityType = parseActivityType(obj["activity_type"] as? String)

        // Parse popup_style (default to notification if missing)
        let popupStyle = parsePopupStyle(obj["popup_style"] as? String)

        return AnnotatedContext(
            taskLabel: taskLabel,
            confidence: confidence,
            summary: summary,
            activityType: activityType,
            popupStyle: popupStyle,
            app: app,
            windowTitle: window,
            timestamp: Date()
        )
    }

    /// Parse activity type string to enum
    private static func parseActivityType(_ raw: String?) -> ActivityType {
        guard let raw = raw?.lowercased().replacingOccurrences(of: "_", with: "") else {
            return .passive  // Conservative default: don't interrupt
        }

        switch raw {
        case "blocked": return .blocked
        case "helpseeking": return .helpSeeking
        case "tedious": return .tedious
        case "passive": return .passive
        case "meeting": return .meeting
        case "productive": return .productive
        default: return .passive  // Conservative default: don't interrupt
        }
    }

    /// Parse popup style string to enum
    private static func parsePopupStyle(_ raw: String?) -> PopupStyle {
        guard let raw = raw?.lowercased() else {
            return .notification  // Default to less intrusive
        }

        switch raw {
        case "cursor": return .cursor
        case "notification": return .notification
        default: return .notification
        }
    }
}

