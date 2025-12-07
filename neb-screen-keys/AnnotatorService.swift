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
    private let ocrClient: DeepSeekOCRClient

    init(grok: GrokClient, capture: ScreenCaptureService, ocrClient: DeepSeekOCRClient? = nil) {
        self.grok = grok
        self.capture = capture
        self.ocrClient = ocrClient ?? DeepSeekOCRClient()
    }

    /// Annotate using a BufferBatch (keystrokes + screen frame + OCR text)
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

        // Extract OCR text if not already provided
        var ocrText = batch.ocrText
        if ocrText == nil {
            Logger.shared.log(.annotator, "Extracting text via OCR...")
            switch await ocrClient.extractText(from: pngData) {
            case .success(let text):
                ocrText = text
                Logger.shared.log(.annotator, "✓ OCR extracted \(text.count) characters")
            case .failure(let error):
                Logger.shared.log(.annotator, "⚠️ OCR failed: \(error.localizedDescription), continuing without OCR text")
                ocrText = nil
            }
        }

        Logger.shared.log(.annotator, "Sending request to Grok (image: \(pngData.count / 1024)KB)...")

        let b64 = pngData.base64EncodedString()
        let imageDataUrl = "data:image/png;base64,\(b64)"

        // Build prompt with keystroke context and OCR text
        let prompt = buildPromptWithOCR(frame: frame, keystrokes: batch.keystrokes, ocrText: ocrText)

        // Build OpenAI-compatible chat request with vision
        let request = GrokRequest(
            model: "grok-4-1-fast-non-reasoning",  // Fast multimodal model
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
        let batch = BufferBatch(keystrokes: "", screenFrame: frame, ocrText: nil, timestamp: Date())
        return await annotate(batch: batch)
    }

    /// Build the Grok prompt with OCR text and keystroke context
    private func buildPromptWithOCR(frame: ScreenFrame, keystrokes: String, ocrText: String?) -> String {
        // Build OCR text section with heavy emphasis
        let ocrSection: String
        if let ocrText = ocrText, !ocrText.isEmpty {
            ocrSection = """
            
            4. **OCR Text Transcript (PRIMARY SOURCE):** The following is a LITERAL, COMPLETE transcript of ALL visible text extracted from the screenshot. This is the GROUND TRUTH - use it as your primary source for ALL details:
            ```
            \(ocrText)
            ```
            
            **CRITICAL OCR USAGE RULES:**
            - The OCR transcript contains EXACT text visible on screen - treat it as the authoritative source
            - Extract and quote EXACT strings from OCR: error messages, function names, file paths, URLs, commands
            - Include specific line numbers, error codes, port numbers, IP addresses, email addresses from OCR
            - Extract button labels, menu items, UI element text exactly as shown in OCR
            - For code editors: extract function signatures, variable names, imports, file paths exactly
            - For terminals: extract commands, output, error messages, file paths exactly
            - For browsers: extract URLs, page titles, form field labels, button text exactly
            - For emails: extract recipient addresses, subject lines, body text snippets exactly
            - DO NOT paraphrase or summarize OCR text - quote it verbatim when providing details
            - The executor needs EXACT strings to perform actions (click buttons, type commands, navigate to URLs)
            """
        } else {
            ocrSection = """
            
            4. **OCR Text Transcript:** Not available for this screenshot. Analyze the image directly.
            """
        }
        
        let keystrokeSection = keystrokes.isEmpty ? "" : """
        
        3. **Recent Keystrokes:** \(keystrokes.count) characters of activity detected. This represents user interaction intensity.
        """
        
        return """
        You are the **Cortex** of an intelligent OS agent. Your capability is **Visual Intent Understanding with Rich Context Extraction**.

        **YOUR INPUTS:**
        1. **Active Window Screenshot:** I am sending you a screenshot of ONLY the user's active window (the application they are currently using). No dock, menu bar, or other windows are visible.
        2. **Clean Context:** You are seeing exactly what the user is focused on - the window content without distractions.
        3. **Metadata:** Active App Name (\(frame.appName)), Window Title (\(frame.windowTitle)).\(keystrokeSection)\(ocrSection)

        **YOUR OBJECTIVE:**
        Analyze the screenshot AND the OCR text transcript to produce a structured "AnnotatedContext" JSON object with RICH, DETAILED, VERBOSE information. This annotation will be used by an executor agent that needs EXACT details to perform UI automation. The more specific and detailed your annotation, the better the executor can complete tasks.

        **CRITICAL ANALYSIS RULES - BE EXTREMELY DETAILED:**
        1. **OCR Text is PRIMARY SOURCE:** When OCR transcript is available, it is the GROUND TRUTH. Extract ALL actionable details from it:
           - Quote EXACT error messages verbatim (e.g., "ConnectionRefusedError: [Errno 61] Connection refused on port 5432")
           - Extract EXACT function names, class names, variable names (e.g., "def processBatch(self, batch: BufferBatch)")
           - Extract EXACT file paths (e.g., "/Users/vagminviswanathan/Desktop/happyNebula/friday/neb-screen-keys/AppCoordinator.swift")
           - Extract EXACT URLs (e.g., "https://api.nebulacloud.app/v1/collections")
           - Extract EXACT terminal commands (e.g., "docker-compose up -d postgres")
           - Extract EXACT button labels, menu items (e.g., "File > Save", "Run > Build")
           - Extract EXACT email addresses, subject lines
           - Extract line numbers, error codes, status codes, port numbers
        2. **Provide Rich Context for Executor:** The executor needs raw material to automate tasks. Include:
           - Exact strings to type, click, or navigate to
           - Specific UI elements (button names, menu paths, field labels)
           - File paths and locations
           - Commands to execute
           - Error messages to search for or fix
           - Code snippets visible on screen
        3. **Be Verbose in Summary:** The summary field should be DETAILED and include:
           - Exact quotes from OCR when relevant
           - Specific file names, function names, error messages
           - Current state of the application (what's open, what's selected, what's visible)
           - What the user is trying to accomplish based on visible context
           - Any blockers or friction points with exact details
        4. **Extract Actionable Details:** Think about what an automation agent would need:
           - What button should be clicked? (exact label from OCR)
           - What command should be typed? (exact command from OCR)
           - What file should be opened? (exact path from OCR)
           - What error should be fixed? (exact error message from OCR)
           - What URL should be navigated to? (exact URL from OCR)
        5. **Window Content Analysis by Type:**
           - **Code Editor:** Extract file path, function names, imports, error messages, line numbers, code snippets
           - **Terminal:** Extract current directory, commands run, command output, error messages, file paths
           - **Browser:** Extract URL, page title, form field labels, button text, search queries
           - **Email:** Extract recipient addresses, subject line, body text snippets, attachment names
           - **IDE/Editor:** Extract open files, active tab, visible code, error messages, build status
        6. **Detect Friction with Specifics:** When user is blocked, include:
           - Exact error message from OCR
           - What command or action caused the error
           - What the user was trying to accomplish
           - What needs to be fixed (specific file, line, configuration)
        7. **Strict Output:** Return ONLY raw JSON. Do not use Markdown blocks (```json). Do not add conversational text.

        **OUTPUT SCHEMA:**
        You must respond with ONLY a valid JSON object matching this structure:
        {
        "task_label": "String. Short, specific intent (e.g., 'Fixing ConnectionRefusedError on Port 5432', 'Composing Email to john@vc.com about Pitch Deck', 'Debugging TypeError in AppCoordinator.swift line 45'). Use OCR text to make this PRECISE with specific details.",
        "confidence": 0.0 to 1.0 (Float). 1.0 = window content is perfectly clear. 0.5 = ambiguous or loading screen.",
        "summary": "String. A VERY DETAILED, VERBOSE description (2-4 sentences) describing what the user is doing. MUST include:
        - Exact quotes from OCR text (error messages, function names, file paths, URLs, commands)
        - Specific details: file names, line numbers, error codes, port numbers, email addresses
        - Current state: what's open, what's selected, what's visible
        - User intent: what they're trying to accomplish
        - Blockers: specific errors or issues preventing progress
        Example: 'User is debugging a ConnectionRefusedError in their terminal. OCR shows exact error: \"ConnectionRefusedError: [Errno 61] Connection refused on port 5432\" from running \"docker-compose up\". The terminal is in directory /Users/vagminviswanathan/Desktop/happyNebula/friday and shows PostgreSQL connection failure. User needs to start the database service or fix the connection configuration.'",
        "activity_type": "String. One of: 'blocked', 'help_seeking', 'tedious', 'passive', 'meeting', 'productive'. You MUST pick one - see definitions below.",
        "popup_style": "String. One of: 'cursor', 'notification'. See definitions below.",
        "app": "String. The confirmed application name.",
        "window_title": "String. The confirmed window title."
        }

        **ACTIVITY TYPE DEFINITIONS (you MUST choose exactly one - no "ambiguous" or "unknown"):**
        - **blocked**: User is STUCK. Errors visible in OCR (red error text, "Connection Refused", compile failures, exceptions, crash logs). Include exact error message from OCR.
        - **help_seeking**: User is SEARCHING for solutions. Stack Overflow visible in OCR, googling error messages, reading GitHub issues, "how to fix" searches. Include exact search query or error being researched.
        - **tedious**: User doing REPETITIVE work that automation could speed up. Formatting code, copy-pasting between apps, running same commands (visible in OCR). Include specific repetitive actions.
        - **passive**: User is READING or CONSUMING content. Documentation, articles, watching videos, casual browsing, social media. Also use for loading screens or unclear contexts.
        - **meeting**: User is in a VIDEO CALL or screen sharing. Zoom, Teams, Meet, FaceTime visible in OCR or screenshot.
        - **productive**: User is IN FLOW. Actively typing code, writing content, making progress. Do NOT interrupt. Include what they're working on specifically.

        **POPUP STYLE DEFINITIONS:**
        - **cursor**: Use when the action is CONTEXTUAL to cursor position. Examples: type a command in terminal at cursor, click a specific button, paste text at insertion point, edit code at current line.
        - **notification**: Use when the action is APP-WIDE or GENERAL. Examples: format entire file, run build command, open new tab/window, switch applications, search Stack Overflow.

        ---

        ### FEW-SHOT EXAMPLES WITH RICH DETAILS

        #### EXAMPLE 1: The "Blocked Engineer" (VERBOSE)
        **Input Context:**
        - App: iTerm2
        - Window: "server_logs — zsh"
        - OCR Text: "vagmin@MacBook-Pro friday % docker-compose up\nStarting postgres...\nERROR: ConnectionRefusedError: [Errno 61] Connection refused on port 5432\nPostgreSQL connection failed\nTraceback (most recent call last):\n  File \"/app/main.py\", line 45, in connect_db\n    conn = psycopg2.connect(host='localhost', port=5432)\npsycopg2.OperationalError: connection refused"
        - Image: Terminal window showing error in red text.

        **GOOD RESPONSE (RICH DETAILS):**
        {
        "task_label": "Fixing PostgreSQL ConnectionRefusedError on Port 5432",
        "confidence": 0.95,
        "summary": "User is debugging a PostgreSQL connection error. OCR shows exact error: 'ConnectionRefusedError: [Errno 61] Connection refused on port 5432' occurring when running 'docker-compose up'. The error originates from '/app/main.py' line 45 in function 'connect_db()' where psycopg2 is attempting to connect to localhost:5432. The PostgreSQL service appears to not be running or not accessible. User needs to either start the PostgreSQL service via 'docker-compose up postgres' or fix the connection configuration in the application.",
        "activity_type": "blocked",
        "popup_style": "cursor",
        "app": "iTerm2",
        "window_title": "server_logs — zsh"
        }

        #### EXAMPLE 2: The "Email Drafter" (VERBOSE)
        **Input Context:**
        - App: Google Chrome
        - Window: "Compose: Pitch Deck - Gmail"
        - OCR Text: "To: john@vc.com\nSubject: Pitch Deck\n\nHi John,\n\nAttached are the financials we discussed in our last meeting on December 5th. The Q4 projections show 40% growth...\n\nBest regards,\nVagmin"
        - Image: Gmail compose window.

        **GOOD RESPONSE (RICH DETAILS):**
        {
        "task_label": "Composing Email to john@vc.com about Pitch Deck with Q4 Financials",
        "confidence": 0.95,
        "summary": "User is composing an email in Gmail to investor john@vc.com. OCR shows exact recipient 'john@vc.com', subject line 'Pitch Deck', and body text referencing a previous meeting on December 5th. The email mentions Q4 financial projections showing 40% growth and includes an attachment. The email is signed 'Vagmin'. User is in the middle of drafting the email body.",
        "activity_type": "productive",
        "popup_style": "cursor",
        "app": "Google Chrome",
        "window_title": "Compose: Pitch Deck - Gmail"
        }

        #### EXAMPLE 3: The "Code Editor" (VERBOSE)
        **Input Context:**
        - App: Cursor
        - Window: "AppCoordinator.swift:45"
        - OCR Text: "import Cocoa\nimport CryptoKit\n\nfinal class AppCoordinator {\n    private let grok: GrokClient\n    \n    init(grokApiKey: String = ProcessInfo.processInfo.environment[\"GROK_API_KEY\"] ?? \"\") {\n        let grokClient = GrokClient(apiKey: grokApiKey)\n        self.grok = grokClient\n    }\n    \n    func startPollingLoop() {\n        // Polling loop implementation\n    }\n}"
        - Image: Code editor showing Swift file with cursor on line 45.

        **GOOD RESPONSE (RICH DETAILS):**
        {
        "task_label": "Implementing GrokClient Initialization in AppCoordinator.swift",
        "confidence": 0.9,
        "summary": "User is working on AppCoordinator.swift, specifically around line 45. OCR shows the file imports Cocoa and CryptoKit, defines a final class AppCoordinator with a private GrokClient property. The init method takes a grokApiKey parameter with default value from environment variable 'GROK_API_KEY', creates a GrokClient instance, and assigns it to self.grok. There's also a startPollingLoop() function visible. User appears to be implementing or modifying the initialization logic for the Grok API client integration.",
        "activity_type": "productive",
        "popup_style": "cursor",
        "app": "Cursor",
        "window_title": "AppCoordinator.swift:45"
        }

        #### EXAMPLE 4: The "Help Seeker" (VERBOSE)
        **Input Context:**
        - App: Arc Browser
        - Window: "python ConnectionRefusedError port 5432 - Stack Overflow"
        - OCR Text: "Stack Overflow\nSearch: python ConnectionRefusedError port 5432\n\nQuestion: How to fix 'ConnectionRefusedError: [Errno 61] Connection refused' on port 5432?\n\nAnswer 1: Make sure PostgreSQL is running: 'sudo service postgresql start'\nAnswer 2: Check if port is in use: 'lsof -i :5432'\nAnswer 3: Verify connection string uses correct host and port..."
        - Image: Browser showing Stack Overflow search results.

        **GOOD RESPONSE (RICH DETAILS):**
        {
        "task_label": "Researching ConnectionRefusedError on Port 5432 on Stack Overflow",
        "confidence": 0.9,
        "summary": "User is searching Stack Overflow for help with a Python ConnectionRefusedError on port 5432. OCR shows exact search query 'python ConnectionRefusedError port 5432' and the question title 'How to fix ConnectionRefusedError: [Errno 61] Connection refused on port 5432?'. Visible answers suggest checking if PostgreSQL is running with 'sudo service postgresql start', checking port usage with 'lsof -i :5432', and verifying connection string. User is actively researching solutions to a database connection issue.",
        "activity_type": "help_seeking",
        "popup_style": "notification",
        "app": "Arc Browser",
        "window_title": "python ConnectionRefusedError port 5432 - Stack Overflow"
        }
        """
    }
    
    /// Build the Grok prompt with keystroke context included (legacy method)
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

