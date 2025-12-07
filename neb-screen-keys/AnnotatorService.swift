//
//  AnnotatorService.swift
//  neb-screen-keys
//

import Cocoa

final class AnnotatorService {
    private let grok: GrokClient
    private let capture: ScreenCaptureService

    init(grok: GrokClient, capture: ScreenCaptureService) {
        self.grok = grok
        self.capture = capture
    }

    func annotate() async -> Result<AnnotatedContext, Error> {
        guard let frame = await capture.captureActiveScreen(),
              let imageData = frame.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: imageData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            let err = NSError(domain: "annotator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to capture screen"])
            return .failure(err)
        }

        let b64 = pngData.base64EncodedString()
        let attachment = GrokAttachment(type: "input_image", image_url: "data:image/png;base64,\(b64)")
                let prompt = """
        You are the **Cortex** of an intelligent OS agent. Your capability is **Visual Intent Understanding**.

        **YOUR INPUTS:**
        1. **Current Screen:** A screenshot of the user's macOS desktop.
        2. **Metadata:** Active App Name (\(frame.appName)), Window Title (\(frame.windowTitle)).

        **YOUR OBJECTIVE:**
        Analyze the screenshot to produce a structured "AnnotatedContext" JSON object. This data is fed directly into a Swift parser, so the schema must be exact.

        **CRITICAL ANALYSIS RULES:**
        1. **Ignore Background Noise:** Focus ONLY on the Active Window defined in the metadata. Ignore background apps.
        2. **OCR & Specificity:** Do not just say "User is coding." Read the text. Extract specific function names, variable names, error codes (e.g., "Postgres 5432"), or email recipients.
        3. **Detect Friction:** High friction includes: Red error text, "Connection Refused", repeatedly refreshing a page, or searching for "how to fix..."
        4. **Continuity Check:** Compare the Current Screen to the `Short-Term Memory`. If the task has changed, note the context switch.
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

        **✅ GOOD RESPONSE:**
        {
        "task_label": "Debugging Infrastructure",
        "confidence": 0.95,
        "summary": "User encountered a 'Connection Refused' error on Port 5432 while deploying. Attempting to restart PostgreSQL.",
        "app": "iTerm2",
        "window_title": "server_logs — zsh"
        }

        **❌ BAD RESPONSE (Vague):**
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

        **✅ GOOD RESPONSE:**
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

        **✅ GOOD RESPONSE:**
        {
        "task_label": "Passive Browsing",
        "confidence": 0.8,
        "summary": "User is casually browsing Hacker News headlines. No specific active task detected.",
        "app": "Safari",
        "window_title": "Hacker News"
        }
        """
        let request = GrokRequest(
            model: "grok-2-latest",
            messages: [
                GrokMessage(role: "user", content: [
                    GrokMessagePart(type: "text", text: prompt)
                ])
            ],
            attachments: [attachment],
            stream: false
        )

        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<AnnotatedContext, Error>, Never>) in
            grok.createResponse(request) { res in
                switch res {
                case .failure(let error):
                    cont.resume(returning: .failure(error))
                case .success(let data):
                    guard let text = String(data: data, encoding: .utf8) else {
                        cont.resume(returning: .failure(NSError(domain: "annotator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Bad Grok response"])))
                        return
                    }
                    let parsed = AnnotatorService.parseAnnotated(jsonText: text,
                                                                 fallbackApp: frame.appName,
                                                                 fallbackWindow: frame.windowTitle)
                    cont.resume(returning: .success(parsed))
                }
            }
        }
        return result
    }

    private static func parseAnnotated(jsonText: String, fallbackApp: String, fallbackWindow: String) -> AnnotatedContext {
        let cleaned = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jsonStart = cleaned.firstIndex(of: "{"),
           let data = String(cleaned[jsonStart...]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            let taskLabel = (obj["task_label"] as? String) ?? "\(fallbackApp) task"
            let confidence = (obj["confidence"] as? Double) ?? 0.5
            let summary = (obj["summary"] as? String) ?? cleaned
            let app = (obj["app"] as? String) ?? fallbackApp
            let window = (obj["window_title"] as? String) ?? fallbackWindow
            return AnnotatedContext(taskLabel: taskLabel,
                                    confidence: confidence,
                                    summary: summary,
                                    app: app,
                                    windowTitle: window,
                                    timestamp: Date())
        }
        return AnnotatedContext(taskLabel: "\(fallbackApp) task",
                                confidence: 0.5,
                                summary: cleaned,
                                app: fallbackApp,
                                windowTitle: fallbackWindow,
                                timestamp: Date())
    }
}

