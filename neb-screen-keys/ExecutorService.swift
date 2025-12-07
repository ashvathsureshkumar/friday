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
    
    /// Generate a quick suggestion preview for the overlay (non-blocking)
    func generateSuggestionPreview(task: AnnotatedContext, completion: @escaping (String) -> Void) {
        // Quick prompt to get just the suggestion, not full execution
        let previewPrompt = """
        Task: \(task.taskLabel)
        App: \(task.app)
        Context: \(task.summary)
        
        In ONE sentence (max 60 characters), describe a SPECIFIC, ACTIONABLE automation.
        Must be something that involves UI interaction: clicking, typing, pasting, running commands.
        Start with an action verb. Be concrete, not abstract.
        
        Good Examples:
        - "Type and run 'brew restart postgresql'"
        - "Paste error message into Google search"
        - "Click Format and run code formatter"
        - "Open new terminal tab and run server"
        
        Bad Examples (too vague):
        - "Help with debugging"
        - "Assist with code"
        - "Check the issue"
        
        Your actionable suggestion:
        """
        
        let request = ChatRequest(
            messages: [ChatMessage(role: "user", content: [.text(previewPrompt)])],
            model: "grok-4-fast",  // Using Grok 4 Fast for quick suggestions
            stream: false,
            temperature: 0.7
        )
        
        Logger.shared.log(.executor, "Generating suggestion preview...")
        
        self.grok.createResponse(request) { result in
            switch result {
            case .failure:
                // Fallback to generic message on error
                completion("I can help: \(task.taskLabel)")
            case .success(let data):
                do {
                    let chatResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                    if let suggestion = chatResponse.choices.first?.message.content {
                        let cleaned = suggestion
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\"", with: "")
                        Logger.shared.log(.executor, "Suggestion: \(cleaned)")
                        completion(cleaned)
                    } else {
                        completion("I can help: \(task.taskLabel)")
                    }
                } catch {
                    completion("I can help: \(task.taskLabel)")
                }
            }
        }
    }

    func planAndExecute(task: AnnotatedContext, keystrokes: String, completion: @escaping (Result<String, Error>) -> Void) {
        Logger.shared.log(.executor, "Searching Nebula for relevant memories: '\(task.taskLabel)'")
        
        nebula.searchMemories(query: task.taskLabel, limit: 5) { [weak self] searchResult in
            guard let self else { return }
            
            let memoriesText: String
            var memoryIdsToDelete: [String] = []  // Track IDs for cleanup
            
            switch searchResult {
            case .failure(let error):
                Logger.shared.log(.executor, "Nebula search failed: \(error.localizedDescription)")
                memoriesText = "No prior memories available."
            case .success(let data):
                if let retrieved = String(data: data, encoding: .utf8), !retrieved.isEmpty {
                    Logger.shared.log(.executor, "Retrieved memories: \(retrieved.count) chars")
                    memoriesText = retrieved
                    
                    // Extract memory IDs for deletion after execution
                    do {
                        let searchResponse = try JSONDecoder().decode(NebulaSearchResponse.self, from: data)
                        if let results = searchResponse.results {
                            for result in results {
                                if let memId = result.memory_id ?? result.id {
                                    memoryIdsToDelete.append(memId)
                                }
                            }
                            Logger.shared.log(.executor, "Tracked \(memoryIdsToDelete.count) memory IDs for cleanup")
                        }
                    } catch {
                        Logger.shared.log(.executor, "Failed to parse search response for IDs: \(error)")
                    }
                } else {
                    memoriesText = "No prior memories available."
                }
            }

            // Build comprehensive execution prompt with ALL retrieved context
            let planPrompt = self.buildExecutionPrompt(
                task: task,
                keystrokes: keystrokes,
                memories: memoriesText
            )
            
            Logger.shared.log(.executor, "Sending execution request to Grok...")
            
            let request = ChatRequest(
                messages: [ChatMessage(role: "user", content: [.text(planPrompt)])],
                model: "grok-4-fast",  // Using Grok 4 Fast for execution planning
                stream: false,
                temperature: 0.7
            )

            self.grok.createResponse(request) { result in
                switch result {
                case .failure(let error):
                    Logger.shared.log(.executor, "Executor API error: \(error.localizedDescription)")
                    completion(.failure(error))
                case .success(let data):
                    do {
                        let chatResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
                        guard let content = chatResponse.choices.first?.message.content else {
                            Logger.shared.log(.executor, "No content in executor response")
                            completion(.failure(NSError(domain: "executor", code: -1,
                                                       userInfo: [NSLocalizedDescriptionKey: "No content"])))
                            return
                        }

                        Logger.shared.log(.executor, "Grok response received: \(content.count) chars")
                        Logger.shared.log(.executor, "Plan generated (\(content.count) chars)")
                        self.executeAppleScriptIfPresent(planText: content)
                        
                        // Cleanup: Delete used memories to prevent infinite growth
                        self.deleteUsedMemories(memoryIdsToDelete)
                        
                        completion(.success(content))
                    } catch {
                        Logger.shared.log(.executor, "Failed to decode executor response: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }
        }
    }
    
    /// Build a comprehensive execution prompt using all available context
    private func buildExecutionPrompt(task: AnnotatedContext, keystrokes: String, memories: String) -> String {
        var promptParts: [String] = []
        
        // Header
        promptParts.append("You are the **Executor** of an intelligent macOS automation agent. You have access to comprehensive context about the user's current task and historical patterns.")
        promptParts.append("")
        
        // Current Task Context
        promptParts.append("## CURRENT TASK CONTEXT")
        promptParts.append("**Task:** \(task.taskLabel)")
        promptParts.append("**Application:** \(task.app)")
        promptParts.append("**Window:** \(task.windowTitle)")
        promptParts.append("**AI Analysis:** \(task.summary)")
        promptParts.append("**Confidence:** \(String(format: "%.0f%%", task.confidence * 100))")
        promptParts.append("")
        
        // User Activity
        if !keystrokes.isEmpty {
            promptParts.append("## USER ACTIVITY SIGNALS")
            promptParts.append("**Keystroke Count:** \(keystrokes.count) characters")
            
            let shortcuts = keystrokes.components(separatedBy: "[SHORTCUT:")
                .dropFirst()
                .compactMap { $0.components(separatedBy: "]").first }
            
            if !shortcuts.isEmpty {
                promptParts.append("**Shortcuts Detected:** \(shortcuts.joined(separator: ", "))")
            }
            
            promptParts.append("**Activity Pattern:** High activity indicates user is actively working, low indicates passive observation.")
            promptParts.append("")
        }
        
        // Historical Context from Nebula
        promptParts.append("## HISTORICAL CONTEXT (Retrieved from Memory)")
        if memories.contains("No prior memories") {
            promptParts.append("No similar tasks found in memory. This appears to be a new type of task.")
        } else {
            promptParts.append(memories)
        }
        promptParts.append("")
        
        // Execution Instructions
        promptParts.append("## YOUR OBJECTIVE")
        promptParts.append("Generate ACTIONABLE AppleScript that performs REAL UI INTERACTIONS:")
        promptParts.append("1. **A numbered action plan** (3-5 steps) explaining specific UI actions")
        promptParts.append("2. **Interactive AppleScript code** that actually clicks, types, pastes, moves cursor, etc.")
        promptParts.append("")
        
        promptParts.append("## CRITICAL REQUIREMENTS - MUST BE ACTIONABLE")
        promptParts.append("Your AppleScript MUST perform actual interactions, not just generic commands.")
        promptParts.append("")
        promptParts.append("**Required Capabilities:**")
        promptParts.append("- **Cursor Movement:** Use System Events to move cursor to specific positions")
        promptParts.append("- **Mouse Clicks:** Click buttons, menu items, UI elements")
        promptParts.append("- **Keyboard Input:** Type text, press keys, use keyboard shortcuts")
        promptParts.append("- **Clipboard Operations:** Copy/paste text and data")
        promptParts.append("- **UI Element Interaction:** Activate windows, focus fields, select items")
        promptParts.append("")
        promptParts.append("**ALWAYS use System Events for UI automation:**")
        promptParts.append("- `keystroke \"text\"` - Type text")
        promptParts.append("- `keystroke \"v\" using command down` - Paste")
        promptParts.append("- `keystroke \"c\" using command down` - Copy")
        promptParts.append("- `keystroke return` - Press Enter")
        promptParts.append("- `key code 53` - Press Escape")
        promptParts.append("- `click at {x, y}` - Click at screen coordinates")
        promptParts.append("- `click menu item \"Name\" of menu \"Menu\"` - Click menu items")
        promptParts.append("")
        promptParts.append("**Use Historical Context:** Learn from similar past tasks")
        promptParts.append("**Safety First:** Avoid destructive actions (no file deletion, no sudo)")
        promptParts.append("**Format:** Enclose code in triple backticks with 'applescript' language tag")
        promptParts.append("")
        
        promptParts.append("## ACTIONABLE EXAMPLES")
        promptParts.append("")
        promptParts.append("### Example 1: Type and Submit in Terminal")
        promptParts.append("```applescript")
        promptParts.append("tell application \"\(task.app)\"")
        promptParts.append("    activate")
        promptParts.append("end tell")
        promptParts.append("delay 0.3")
        promptParts.append("tell application \"System Events\"")
        promptParts.append("    keystroke \"brew services restart postgresql\"")
        promptParts.append("    delay 0.2")
        promptParts.append("    keystroke return")
        promptParts.append("end tell")
        promptParts.append("```")
        promptParts.append("")
        promptParts.append("### Example 2: Copy Text and Paste Elsewhere")
        promptParts.append("```applescript")
        promptParts.append("tell application \"System Events\"")
        promptParts.append("    -- Select all text")
        promptParts.append("    keystroke \"a\" using command down")
        promptParts.append("    delay 0.1")
        promptParts.append("    -- Copy")
        promptParts.append("    keystroke \"c\" using command down")
        promptParts.append("    delay 0.2")
        promptParts.append("    -- Switch application")
        promptParts.append("    keystroke tab using command down")
        promptParts.append("    delay 0.3")
        promptParts.append("    -- Paste")
        promptParts.append("    keystroke \"v\" using command down")
        promptParts.append("end tell")
        promptParts.append("```")
        promptParts.append("")
        promptParts.append("### Example 3: Click UI Element and Type")
        promptParts.append("```applescript")
        promptParts.append("tell application \"\(task.app)\"")
        promptParts.append("    activate")
        promptParts.append("end tell")
        promptParts.append("delay 0.5")
        promptParts.append("tell application \"System Events\"")
        promptParts.append("    tell process \"\(task.app)\"")
        promptParts.append("        -- Click search field")
        promptParts.append("        click text field 1 of window 1")
        promptParts.append("        delay 0.2")
        promptParts.append("        -- Type search query")
        promptParts.append("        keystroke \"PostgreSQL connection error\"")
        promptParts.append("        delay 0.1")
        promptParts.append("        keystroke return")
        promptParts.append("    end tell")
        promptParts.append("end tell")
        promptParts.append("```")
        promptParts.append("")
        promptParts.append("### Example 4: Menu Navigation")
        promptParts.append("```applescript")
        promptParts.append("tell application \"\(task.app)\"")
        promptParts.append("    activate")
        promptParts.append("end tell")
        promptParts.append("delay 0.3")
        promptParts.append("tell application \"System Events\"")
        promptParts.append("    tell process \"\(task.app)\"")
        promptParts.append("        click menu item \"Format Document\" of menu \"Edit\" of menu bar 1")
        promptParts.append("    end tell")
        promptParts.append("end tell")
        promptParts.append("```")
        promptParts.append("")
        promptParts.append("### Example 5: Open New Window and Type")
        promptParts.append("```applescript")
        promptParts.append("tell application \"\(task.app)\"")
        promptParts.append("    activate")
        promptParts.append("end tell")
        promptParts.append("delay 0.3")
        promptParts.append("tell application \"System Events\"")
        promptParts.append("    -- Open new tab/window")
        promptParts.append("    keystroke \"t\" using command down")
        promptParts.append("    delay 0.5")
        promptParts.append("    -- Type command")
        promptParts.append("    keystroke \"python manage.py runserver\"")
        promptParts.append("    keystroke return")
        promptParts.append("end tell")
        promptParts.append("```")
        promptParts.append("")
        promptParts.append("## IMPORTANT GUIDELINES")
        promptParts.append("1. **Always activate the target application first**")
        promptParts.append("2. **Add short delays (0.2-0.5s) between actions for UI responsiveness**")
        promptParts.append("3. **Use specific keystrokes for shortcuts (Cmd, Option, Control, Shift)**")
        promptParts.append("4. **Click actual UI elements when possible (buttons, fields, menus)**")
        promptParts.append("5. **Type actual text that helps the user, don't just run abstract commands**")
        promptParts.append("")
        
        promptParts.append("## COMMON AUTOMATION PATTERNS BY TASK TYPE")
        promptParts.append("")
        promptParts.append("**Terminal/iTerm Tasks:**")
        promptParts.append("- Type and execute commands (brew, npm, python, etc.)")
        promptParts.append("- Open new tabs/windows for parallel work")
        promptParts.append("- Paste error messages or URLs")
        promptParts.append("")
        promptParts.append("**Code Editor Tasks (VSCode, Xcode, etc.):**")
        promptParts.append("- Format code (Cmd+Shift+F or menu)")
        promptParts.append("- Find/replace text (Cmd+F)")
        promptParts.append("- Run linter/formatter via menu")
        promptParts.append("- Insert code snippets via typing")
        promptParts.append("")
        promptParts.append("**Browser Tasks:**")
        promptParts.append("- Open new tab and search")
        promptParts.append("- Copy URL and paste into search")
        promptParts.append("- Navigate via address bar (Cmd+L)")
        promptParts.append("")
        promptParts.append("**Documentation/Research:**")
        promptParts.append("- Open Stack Overflow with error message")
        promptParts.append("- Search documentation sites")
        promptParts.append("- Copy relevant text to clipboard")
        promptParts.append("")
        promptParts.append("**Communication Tasks:**")
        promptParts.append("- Compose email with template")
        promptParts.append("- Insert signature or boilerplate")
        promptParts.append("- Format message text")
        promptParts.append("")
        
        promptParts.append("---")
        promptParts.append("")
        promptParts.append("## NOW GENERATE YOUR ACTIONABLE RESPONSE")
        promptParts.append("")
        promptParts.append("Based on the context above:")
        promptParts.append("- Task: \(task.taskLabel)")
        promptParts.append("- App: \(task.app)")
        promptParts.append("")
        promptParts.append("Provide:")
        promptParts.append("1. Action plan (numbered list of specific UI interactions)")
        promptParts.append("2. Complete AppleScript with actual keystrokes, clicks, and text input")
        promptParts.append("")
        promptParts.append("Make it ACTIONABLE and INTERACTIVE!")
        
        return promptParts.joined(separator: "\n")
    }

    /// Delete used memories to prevent collection from growing infinitely
    private func deleteUsedMemories(_ memoryIds: [String]) {
        guard !memoryIds.isEmpty else {
            Logger.shared.log(.executor, "No memories to delete")
            return
        }
        
        Logger.shared.log(.executor, "Cleaning up \(memoryIds.count) used memories...")
        
        // Delete each memory asynchronously
        for memId in memoryIds {
            nebula.deleteMemory(memoryId: memId) { result in
                switch result {
                case .success:
                    Logger.shared.log(.executor, "✓ Deleted memory: \(memId)")
                case .failure(let error):
                    Logger.shared.log(.executor, "⚠️ Failed to delete memory \(memId): \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func executeAppleScriptIfPresent(planText: String) {
        Logger.shared.log(.executor, "Searching for AppleScript in response...")
        
        guard let scriptRangeStart = planText.range(of: "```applescript"),
              let scriptRangeEnd = planText.range(of: "```", range: scriptRangeStart.upperBound..<planText.endIndex) else {
            Logger.shared.log(.executor, "No AppleScript block found in response")
            return
        }
        
        let scriptBody = String(planText[scriptRangeStart.upperBound..<scriptRangeEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        Logger.shared.log(.executor, "AppleScript extracted (\(scriptBody.count) chars)")
        Logger.shared.log(.executor, "Executing AppleScript...")
        
        let appleScript = NSAppleScript(source: scriptBody)
        var errorDict: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorDict)
        
        if let errorDict {
            Logger.shared.log(.executor, "AppleScript execution error: \(errorDict)")
        } else if let result {
            Logger.shared.log(.executor, "AppleScript executed successfully: \(result.stringValue ?? "no return value")")
        } else {
            Logger.shared.log(.executor, "AppleScript executed (no return value)")
        }
    }
}

