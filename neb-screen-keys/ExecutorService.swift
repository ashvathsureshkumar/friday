//
//  ExecutorService.swift
//  neb-screen-keys
//

import Cocoa

final class ExecutorService {
    private let grok: GrokClient
    private let nebula: NebulaClient

    init(grok: GrokClient, nebula: NebulaClient) {
        self.grok = grok
        self.nebula = nebula
    }

    func planAndExecute(task: AnnotatedContext, completion: @escaping (Result<String, Error>) -> Void) {
        nebula.searchMemories(query: task.taskLabel, limit: 5) { [weak self] searchResult in
            guard let self else { return }
            let memoriesText: String
            switch searchResult {
            case .failure:
                memoriesText = "No prior memories."
            case .success(let data):
                memoriesText = String(data: data, encoding: .utf8) ?? "No prior memories."
            }

            let planPrompt = """
            Context: \(task.summary)
            Memories: \(memoriesText)
            Task: \(task.taskLabel)
            Produce a concise numbered plan and an AppleScript block (triple backtick fenced with language applescript) to execute safely. Avoid destructive actions.
            """
            let request = GrokRequest(
                model: "grok-2-latest",
                messages: [GrokMessage(role: "user", content: [GrokMessagePart(type: "text", text: planPrompt)])],
                attachments: nil,
                stream: false
            )

            self.grok.createResponse(request) { result in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let data):
                    let responseText = String(data: data, encoding: .utf8) ?? "No response"
                    self.executeAppleScriptIfPresent(planText: responseText)
                    completion(.success(responseText))
                }
            }
        }
    }

    private func executeAppleScriptIfPresent(planText: String) {
        guard let scriptRangeStart = planText.range(of: "```applescript"),
              let scriptRangeEnd = planText.range(of: "```", range: scriptRangeStart.upperBound..<planText.endIndex) else {
            return
        }
        let scriptBody = String(planText[scriptRangeStart.upperBound..<scriptRangeEnd.lowerBound])
        let appleScript = NSAppleScript(source: scriptBody)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)
        if let errorDict {
            print("AppleScript error: \(errorDict)")
        }
    }
}

