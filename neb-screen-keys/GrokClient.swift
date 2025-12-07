//
//  GrokClient.swift
//  neb-screen-keys
//

import Foundation

// MARK: - Image URL Structure

struct ImageUrl: Codable {
    let url: String
}

// MARK: - Content Part (Polymorphic)

enum ContentPart: Codable {
    case text(String)
    case imageUrl(ImageUrl)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "image_url":
            let imageUrl = try container.decode(ImageUrl.self, forKey: .imageUrl)
            self = .imageUrl(imageUrl)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageUrl(let imageUrl):
            try container.encode("image_url", forKey: .type)
            try container.encode(imageUrl, forKey: .imageUrl)
        }
    }
}

// MARK: - Grok Message Part

struct GrokMessagePart: Codable {
    let type: String
    let text: String?
    let imageUrl: ImageUrl?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
    }

    init(type: String, text: String? = nil, imageUrl: ImageUrl? = nil) {
        self.type = type
        self.text = text
        self.imageUrl = imageUrl
    }
}

// MARK: - Grok Message

struct GrokMessage: Codable {
    let role: String
    let content: [GrokMessagePart]
}

// MARK: - Grok Request

struct GrokRequest: Codable {
    let model: String
    let messages: [GrokMessage]
    let attachments: [String]?
    let stream: Bool
}

// MARK: - Grok Client

final class GrokClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        // Strip any "Bearer " prefix if accidentally included
        let cleanKey = apiKey.replacingOccurrences(of: "Bearer ", with: "")
        self.apiKey = cleanKey
        self.session = session
        
        // Validation and logging
        if cleanKey.isEmpty {
            Logger.shared.log(.system, "⚠️ WARNING: GrokClient initialized with EMPTY API key!")
            Logger.shared.log(.system, "   Check that GROK_API_KEY is set in your .env file")
            Logger.shared.log(.system, "   Expected format: GROK_API_KEY=xai-...")
        } else if !cleanKey.hasPrefix("xai-") {
            Logger.shared.log(.system, "⚠️ WARNING: GrokClient API key does not start with 'xai-'")
            Logger.shared.log(.system, "   Key format: \(cleanKey.prefix(10))...")
        } else {
            Logger.shared.log(.system, "✓ GrokClient initialized with valid API key format")
        }
    }

    func createResponse(_ payload: GrokRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        // Validate API key before making request
        if apiKey.isEmpty {
            Logger.shared.log(.annotator, "❌ ERROR: Cannot make Grok API request - API key is EMPTY")
            Logger.shared.log(.annotator, "   Check that GROK_API_KEY is set in ~/.config/neb-screen-keys/.env or .env")
            let error = NSError(
                domain: "grok",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Missing GROK_API_KEY - check .env file"]
            )
            completion(.failure(error))
            return
        }

        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
            completion(.failure(NSError(domain: "grok", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Log headers for debugging (without exposing full key)
        Logger.shared.log(.annotator, "Request headers: Content-Type=application/json, Authorization=Bearer \(apiKey.prefix(10))...")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(payload)
            request.httpBody = jsonData

            // Log summary without the massive base64 image
            let hasImage = payload.messages.contains { message in
                message.content.contains { part in
                    part.imageUrl != nil
                }
            }
            Logger.shared.log(.annotator, "Sending Grok request: model=\(payload.model), messages=\(payload.messages.count), hasImage=\(hasImage), size=\(jsonData.count / 1024)KB")
        } catch {
            Logger.shared.log(.annotator, "Failed to encode request: \(error.localizedDescription)")
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.shared.log(.annotator, "Network error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse {
                Logger.shared.log(.annotator, "API Response Status: \(httpResponse.statusCode)")

                if httpResponse.statusCode != 200 {
                    if let data = data, let errorBody = String(data: data, encoding: .utf8) {
                        Logger.shared.log(.annotator, "API Error Response: \(errorBody)")
                    }
                }
            }

            completion(.success(data ?? Data()))
        }.resume()
    }
}

