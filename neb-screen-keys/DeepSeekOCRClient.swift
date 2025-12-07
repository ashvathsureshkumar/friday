//
//  DeepSeekOCRClient.swift
//  neb-screen-keys
//

import Foundation

/// Client for DeepSeek OCR via Hugging Face to extract text from screenshots
final class DeepSeekOCRClient {
    private let apiKey: String
    private let session: URLSession
    private let useLocalPython: Bool
    
    init(apiKey: String? = nil, useLocalPython: Bool = false) {
        // Get API key from environment or parameter (Hugging Face token)
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["HUGGINGFACE_API_KEY"] ?? "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"
        self.session = URLSession.shared
        self.useLocalPython = useLocalPython
        
        if useLocalPython {
            Logger.shared.log(.annotator, "✓ DeepSeekOCRClient initialized with local Python script")
        } else if self.apiKey.isEmpty {
            Logger.shared.log(.annotator, "⚠️ WARNING: DeepSeekOCRClient initialized with EMPTY API key! Set HUGGINGFACE_API_KEY")
        } else {
            Logger.shared.log(.annotator, "✓ DeepSeekOCRClient initialized with Hugging Face API key")
        }
    }
    
    /// Extract text from screenshot using DeepSeek OCR via Hugging Face
    func extractText(from imageData: Data) async -> Result<String, Error> {
        if useLocalPython {
            return await extractTextViaPython(imageData: imageData)
        } else {
            return await extractTextViaHuggingFaceAPI(imageData: imageData)
        }
    }
    
    /// Extract text using Hugging Face Inference API
    private func extractTextViaHuggingFaceAPI(imageData: Data) async -> Result<String, Error> {
        guard !apiKey.isEmpty else {
            return .failure(NSError(domain: "deepseek-ocr", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing HUGGINGFACE_API_KEY"]))
        }
        
        // Hugging Face Inference API endpoint for DeepSeek-OCR (using new router endpoint)
        guard let url = URL(string: "https://router.huggingface.co/hf-inference/models/deepseek-ai/DeepSeek-OCR") else {
            return .failure(NSError(domain: "deepseek-ocr", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"]))
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = imageData
        
        Logger.shared.log(.annotator, "Sending OCR request to Hugging Face Inference API...")
        
        return await withCheckedContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error = error {
                    Logger.shared.log(.annotator, "OCR network error: \(error.localizedDescription)")
                    continuation.resume(returning: .failure(error))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(returning: .failure(NSError(domain: "deepseek-ocr", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])))
                    return
                }
                
                guard httpResponse.statusCode == 200, let data = data else {
                    let errorBody = String(data: data ?? Data(), encoding: .utf8) ?? "Unknown error"
                    Logger.shared.log(.annotator, "OCR API error (status \(httpResponse.statusCode)): \(errorBody)")
                    continuation.resume(returning: .failure(NSError(domain: "deepseek-ocr", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "OCR API error: \(errorBody)"])))
                    return
                }
                
                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    
                    // Hugging Face OCR typically returns text in a "text" field or array of results
                    if let text = json?["text"] as? String {
                        Logger.shared.log(.annotator, "✓ OCR extracted \(text.count) characters of text")
                        continuation.resume(returning: .success(text))
                    } else if let results = json?["results"] as? [[String: Any]],
                              let firstResult = results.first,
                              let text = firstResult["text"] as? String {
                        Logger.shared.log(.annotator, "✓ OCR extracted \(text.count) characters of text")
                        continuation.resume(returning: .success(text))
                    } else if let generatedText = json?["generated_text"] as? String {
                        Logger.shared.log(.annotator, "✓ OCR extracted \(generatedText.count) characters of text")
                        continuation.resume(returning: .success(generatedText))
                    } else {
                        // Try to extract any text field from the response
                        let jsonString = String(data: data, encoding: .utf8) ?? "{}"
                        Logger.shared.log(.annotator, "⚠️ Unexpected OCR response format: \(jsonString.prefix(200))")
                        continuation.resume(returning: .failure(NSError(domain: "deepseek-ocr", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid OCR response format - no text field found"])))
                    }
                } catch {
                    Logger.shared.log(.annotator, "OCR JSON parse error: \(error.localizedDescription)")
                    continuation.resume(returning: .failure(error))
                }
            }.resume()
        }
    }
    
    /// Extract text using local Python script (requires Python with transformers installed)
    private func extractTextViaPython(imageData: Data) async -> Result<String, Error> {
        // Save image to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("ocr_input_\(UUID().uuidString).png")
        
        guard (try? imageData.write(to: tempFile)) != nil else {
            return .failure(NSError(domain: "deepseek-ocr", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to write temp image file"]))
        }
        
        // Find Python script - check bundle resources first, then project directory
        let scriptPath: String
        if let bundlePath = Bundle.main.resourcePath,
           FileManager.default.fileExists(atPath: bundlePath + "/ocr_extract.py") {
            scriptPath = bundlePath + "/ocr_extract.py"
        } else if let projectRoot = ProcessInfo.processInfo.environment["WORKSPACE_PATH"],
                  FileManager.default.fileExists(atPath: projectRoot + "/neb-screen-keys/ocr_extract.py") {
            scriptPath = projectRoot + "/neb-screen-keys/ocr_extract.py"
        } else {
            // Fallback: use temp directory and create script there
            scriptPath = tempDir.appendingPathComponent("ocr_extract.py").path
        }
        
        // Check if Python script exists, if not return error (user should create it)
        if !FileManager.default.fileExists(atPath: scriptPath) {
            return .failure(NSError(domain: "deepseek-ocr", code: -1, userInfo: [NSLocalizedDescriptionKey: "Python OCR script not found at \(scriptPath). Please ensure ocr_extract.py exists and has required dependencies installed."]))
        }
        
        Logger.shared.log(.annotator, "Running local Python OCR script...")
        
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [scriptPath, tempFile.path]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                
                // Clean up temp file
                try? FileManager.default.removeItem(at: tempFile)
                
                if process.terminationStatus == 0 {
                    // Parse JSON output
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let text = json["text"] as? String {
                        Logger.shared.log(.annotator, "✓ OCR extracted \(text.count) characters of text")
                        continuation.resume(returning: .success(text))
                    } else {
                        continuation.resume(returning: .failure(NSError(domain: "deepseek-ocr", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Python script output"])))
                    }
                } else {
                    Logger.shared.log(.annotator, "Python OCR script error: \(output)")
                    continuation.resume(returning: .failure(NSError(domain: "deepseek-ocr", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Python script failed: \(output)"])))
                }
            } catch {
                try? FileManager.default.removeItem(at: tempFile)
                Logger.shared.log(.annotator, "Failed to run Python script: \(error.localizedDescription)")
                continuation.resume(returning: .failure(error))
            }
        }
    }
}
