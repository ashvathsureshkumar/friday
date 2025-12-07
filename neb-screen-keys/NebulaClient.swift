//
//  NebulaClient.swift
//  neb-screen-keys
//

import Foundation

final class NebulaClient {
    private let apiKey: String
    private let collectionId: String
    private let baseURL = URL(string: "https://mcp.nebulacloud.app/mcp")!
    private let session: URLSession

    init(apiKey: String, collectionId: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.collectionId = collectionId
        self.session = session
    }

    func addMemory(content: String, metadata: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "add_memory",
            "params": [
                "content": content,
                "metadata": metadata
            ]
        ]
        post(body: body) { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func searchMemories(query: String, limit: Int = 5, completion: @escaping (Result<Data, Error>) -> Void) {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "search_memories",
            "params": [
                "query": query,
                "limit": limit
            ]
        ]
        post(body: body, completion: completion)
    }

    private func post(body: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue(collectionId, forHTTPHeaderField: "X-Collection-ID")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
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

