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

// MARK: - Chat Message

struct ChatMessage: Codable {
    let role: String
    let content: [ContentPart]
}

// MARK: - Chat Request

struct ChatRequest: Codable {
    let messages: [ChatMessage]
    let model: String
    let stream: Bool
    let temperature: Double
}

// MARK: - Grok Client

final class GrokClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func createResponse(_ payload: ChatRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
            completion(.failure(NSError(domain: "grok", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(payload)
            request.httpBody = jsonData

            // Log summary without the massive base64 image
            let hasImage = payload.messages.contains { message in
                message.content.contains { part in
                    if case .imageUrl = part { return true }
                    return false
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

