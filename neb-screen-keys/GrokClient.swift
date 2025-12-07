//
//  GrokClient.swift
//  neb-screen-keys
//

import Foundation

struct GrokMessagePart: Codable {
    let type: String
    let text: String?
}

struct GrokMessage: Codable {
    let role: String
    let content: [GrokMessagePart]
}

struct GrokAttachment: Codable {
    let type: String
    let image_url: String?
}

struct GrokRequest: Codable {
    let model: String
    let messages: [GrokMessage]
    let attachments: [GrokAttachment]?
    let stream: Bool?
}

final class GrokClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func createResponse(_ payload: GrokRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let url = URL(string: "https://api.x.ai/v1/responses") else {
            completion(.failure(NSError(domain: "grok", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"])))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            completion(.success(data ?? Data()))
        }.resume()
    }
}

