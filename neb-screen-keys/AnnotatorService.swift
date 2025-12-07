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

    func annotate(completion: @escaping (Result<AnnotatedContext, Error>) -> Void) {
        guard let frame = capture.captureActiveScreen(),
              let imageData = frame.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: imageData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            completion(.failure(NSError(domain: "annotator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to capture screen"])))
            return
        }

        let b64 = pngData.base64EncodedString()
        let attachment = GrokAttachment(type: "input_image", image_url: "data:image/png;base64,\(b64)")
        let prompt = """
        You are an annotator. Return ONLY JSON with fields: task_label, confidence (0-1), summary, app, window_title. No prose.
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

        grok.createResponse(request) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                guard let text = String(data: data, encoding: .utf8) else {
                    completion(.failure(NSError(domain: "annotator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Bad Grok response"])))
                    return
                }
                let parsed = AnnotatorService.parseAnnotated(jsonText: text,
                                                             fallbackApp: frame.appName,
                                                             fallbackWindow: frame.windowTitle)
                completion(.success(parsed))
            }
        }
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

