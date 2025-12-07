//
//  NebulaClient.swift
//  neb-screen-keys
//

import Foundation

final class NebulaClient {
    private let apiKey: String
    private let collectionId: String
    private let baseURL = URL(string: "https://api.nebulacloud.app")!
    private let session: URLSession

    init(apiKey: String, collectionId: String, session: URLSession = .shared) {
        // Nebula API keys should start with "neb_" according to their docs
        // Accept keys with or without "Bearer " prefix
        let cleanKey = apiKey.replacingOccurrences(of: "Bearer ", with: "")
        self.apiKey = cleanKey
        self.collectionId = collectionId
        self.session = session
        
        // Log initialization for debugging
        Logger.shared.log(.nebula, "Initialized Nebula client")
        Logger.shared.log(.nebula, "  Base URL: \(baseURL.absoluteString)")
        Logger.shared.log(.nebula, "  API Key format: \(cleanKey.hasPrefix("neb_") ? "✓ Valid (neb_...)" : "⚠️ Unexpected format")")
        Logger.shared.log(.nebula, "  Collection ID: \(collectionId)")
    }

    func addMemory(content: String, metadata: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        let contentPreview = content.count > 100 ? String(content.prefix(100)) + "..." : content
        Logger.shared.log(.nebula, "Adding memory: \(contentPreview)")
        
        // Using Nebula's Python SDK as reference: https://docs.trynebula.ai/clients/python
        // The store_memory method requires collection_id, content, and metadata
        let body: [String: Any] = [
            "collection_id": collectionId,
            "content": content,
            "metadata": metadata
        ]
        
        // Log summary, not full payload (can be huge)
        Logger.shared.log(.nebula, "Method: store_memory, Content: \(content.count) chars, Metadata keys: \(metadata.keys.joined(separator: ", "))")
        
        postToStoreMemory(body: body) { result in
            switch result {
            case .success(let data):
                // Log the response (but limit length)
                if let responseString = String(data: data, encoding: .utf8) {
                    let preview = responseString.count > 200 ? String(responseString.prefix(200)) + "..." : responseString
                    Logger.shared.log(.nebula, "Response: \(preview)")
                }
                
                // Parse response to check for success
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Check if we got a memory_id back (indicates success)
                    if json["memory_id"] != nil || json["id"] != nil {
                        Logger.shared.log(.nebula, "Memory stored successfully")
                        completion(.success(()))
                        return
                    }
                }
                
                // If we got a 200 response but unexpected format, still consider it success
                Logger.shared.log(.nebula, "Memory stored (response format may vary)")
                completion(.success(()))
                
            case .failure(let error):
                Logger.shared.log(.nebula, "Network error: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    func searchMemories(query: String, limit: Int = 5, completion: @escaping (Result<Data, Error>) -> Void) {
        Logger.shared.log(.nebula, "Searching memories: query='\(query)', limit=\(limit)")
        
        // Using Nebula's Python SDK as reference: https://docs.trynebula.ai/clients/python
        // The search method requires query, collection_ids (array), and limit
        let body: [String: Any] = [
            "query": query,
            "collection_ids": [collectionId],  // Array of collection IDs
            "limit": limit
        ]
        
        postToSearch(body: body) { result in
            switch result {
            case .success(let data):
                if let responseString = String(data: data, encoding: .utf8) {
                    let preview = responseString.count > 300 ? String(responseString.prefix(300)) + "..." : responseString
                    Logger.shared.log(.nebula, "Search response: \(preview)")
                }
                completion(.success(data))
            case .failure(let error):
                Logger.shared.log(.nebula, "Search error: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    // POST to store_memory endpoint (using correct Nebula base URL)
    private func postToStoreMemory(body: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        let storeURL = baseURL.appendingPathComponent("v1/memories")
        var request = URLRequest(url: storeURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        Logger.shared.log(.nebula, "POST \(storeURL.absoluteString)")
        Logger.shared.log(.nebula, "Auth: Bearer \(apiKey.prefix(15))...")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            Logger.shared.log(.nebula, "Serialization error: \(error.localizedDescription)")
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.shared.log(.nebula, "Request failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                Logger.shared.log(.nebula, "HTTP \(httpResponse.statusCode)")
                
                // Accept 200 and 201 as success
                if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
                    if let data = data, let errorBody = String(data: data, encoding: .utf8) {
                        let preview = errorBody.count > 200 ? String(errorBody.prefix(200)) + "..." : errorBody
                        Logger.shared.log(.nebula, "Error body: \(preview)")
                        
                        let error = NSError(domain: "nebula", 
                                          code: httpResponse.statusCode,
                                          userInfo: [NSLocalizedDescriptionKey: errorBody])
                        completion(.failure(error))
                        return
                    }
                }
            }
            
            completion(.success(data ?? Data()))
        }.resume()
    }
    
    // POST to search endpoint (using correct Nebula base URL)
    private func postToSearch(body: [String: Any], completion: @escaping (Result<Data, Error>) -> Void) {
        let searchURL = baseURL.appendingPathComponent("v1/search")
        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        Logger.shared.log(.nebula, "POST \(searchURL.absoluteString)")
        Logger.shared.log(.nebula, "Auth: Bearer \(apiKey.prefix(15))...")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            Logger.shared.log(.nebula, "Serialization error: \(error.localizedDescription)")
            completion(.failure(error))
            return
        }

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.shared.log(.nebula, "Request failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                Logger.shared.log(.nebula, "HTTP \(httpResponse.statusCode)")
                
                // Treat non-200 as failure
                if httpResponse.statusCode != 200 {
                    if let data = data, let errorBody = String(data: data, encoding: .utf8) {
                        let preview = errorBody.count > 200 ? String(errorBody.prefix(200)) + "..." : errorBody
                        Logger.shared.log(.nebula, "Error body: \(preview)")
                        
                        let error = NSError(domain: "nebula", 
                                          code: httpResponse.statusCode,
                                          userInfo: [NSLocalizedDescriptionKey: errorBody])
                        completion(.failure(error))
                        return
                    }
                }
            }
            
            completion(.success(data ?? Data()))
        }.resume()
    }
}

