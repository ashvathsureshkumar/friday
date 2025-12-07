//
//  NebulaClient.swift
//  neb-screen-keys
//

import Foundation

// MARK: - Nebula API Request/Response Structures

/// Request structure for storing a memory in Nebula
struct NebulaMemoryRequest: Codable {
    let content: String
    let metadata: [String: String]
    let collection_ref: String      // Server expects "collection_ref" not "collection_id"
    let engram_type: String         // Required field for memory type
    
    enum CodingKeys: String, CodingKey {
        case content = "raw_text"
        case metadata
        case collection_ref
        case engram_type
    }
}

/// Request structure for searching memories in Nebula
struct NebulaSearchRequest: Codable {
    let query: String
    let collection_ids: [String]    // Array of collection IDs to search
    let limit: Int
    
    enum CodingKeys: String, CodingKey {
        case query
        case collection_ids
        case limit
    }
}

/// Response structure for stored memory
struct NebulaMemoryResponse: Codable {
    let id: String?
    let memory_id: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case memory_id
    }
}

// MARK: - Nebula Client

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
        
        // Convert metadata to [String: String] for Codable compliance
        // Nebula expects string values, so convert any non-string values to strings
        let stringMetadata = metadata.mapValues { value -> String in
            if let stringValue = value as? String {
                return stringValue
            } else if let numberValue = value as? NSNumber {
                return numberValue.stringValue
            } else if let boolValue = value as? Bool {
                return boolValue ? "true" : "false"
            } else {
                return String(describing: value)
            }
        }
        
        // Create properly structured request per Nebula API docs
        let request = NebulaMemoryRequest(
            content: content,
            metadata: stringMetadata,
            collection_ref: collectionId,      // Use collection_ref as server expects
            engram_type: "document"            // Valid types: "conversation" or "document"
        )
        
        // Log summary
        Logger.shared.log(.nebula, "Storing: content=\(content.count)chars, metadata=\(stringMetadata.keys.count)keys, type=document")
        
        postToStoreMemory(request: request) { result in
            switch result {
            case .success(let data):
                // Log the response (but limit length)
                if let responseString = String(data: data, encoding: .utf8) {
                    let preview = responseString.count > 200 ? String(responseString.prefix(200)) + "..." : responseString
                    Logger.shared.log(.nebula, "Response: \(preview)")
                }
                
                // Try to parse response
                do {
                    let response = try JSONDecoder().decode(NebulaMemoryResponse.self, from: data)
                    if response.id != nil || response.memory_id != nil {
                        Logger.shared.log(.nebula, "Memory stored successfully (id: \(response.id ?? response.memory_id ?? "unknown"))")
                        completion(.success(()))
                    } else {
                        Logger.shared.log(.nebula, "Memory stored (no ID returned)")
                        completion(.success(()))
                    }
                } catch {
                    // If we got 200/201 but can't parse, still consider it success
                    Logger.shared.log(.nebula, "Memory stored (parse error: \(error.localizedDescription))")
                    completion(.success(()))
                }
                
            case .failure(let error):
                Logger.shared.log(.nebula, "Store memory failed: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }

    func searchMemories(query: String, limit: Int = 5, completion: @escaping (Result<Data, Error>) -> Void) {
        Logger.shared.log(.nebula, "Searching memories: query='\(query)', limit=\(limit)")
        
        // Create properly structured search request per Nebula API docs
        let request = NebulaSearchRequest(
            query: query,
            collection_ids: [collectionId],    // Server expects array of collection IDs
            limit: limit
        )
        
        postToSearch(request: request) { result in
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

    // POST to store_memory endpoint using proper Codable struct
    private func postToStoreMemory(request: NebulaMemoryRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        let storeURL = baseURL.appendingPathComponent("v1/memories")
        var urlRequest = URLRequest(url: storeURL)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        Logger.shared.log(.nebula, "POST \(storeURL.absoluteString)")

        do {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(request)
            
            // Log the actual JSON being sent for debugging
            if let jsonString = String(data: urlRequest.httpBody!, encoding: .utf8) {
                Logger.shared.log(.nebula, "Request body: \(jsonString)")
            }
        } catch {
            Logger.shared.log(.nebula, "Encoding error: \(error.localizedDescription)")
            completion(.failure(error))
            return
        }

        session.dataTask(with: urlRequest) { data, response, error in
            if let error = error {
                Logger.shared.log(.nebula, "Request failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                Logger.shared.log(.nebula, "HTTP \(httpResponse.statusCode)")
                
                // Accept all 2xx status codes as success (200-299)
                if !(200...299).contains(httpResponse.statusCode) {
                    if let data = data, let errorBody = String(data: data, encoding: .utf8) {
                        let preview = errorBody.count > 300 ? String(errorBody.prefix(300)) + "..." : errorBody
                        Logger.shared.log(.nebula, "Error (\(httpResponse.statusCode)): \(preview)")
                        
                        let error = NSError(domain: "nebula", 
                                          code: httpResponse.statusCode,
                                          userInfo: [NSLocalizedDescriptionKey: errorBody])
                        completion(.failure(error))
                        return
                    }
                }
                
                // Special logging for 202 Accepted (async processing)
                if httpResponse.statusCode == 202 {
                    Logger.shared.log(.nebula, "✅ Memory queued successfully (Async processing)")
                }
            }
            
            completion(.success(data ?? Data()))
        }.resume()
    }
    
    // POST to search endpoint using proper Codable struct
    private func postToSearch(request: NebulaSearchRequest, completion: @escaping (Result<Data, Error>) -> Void) {
        let searchURL = baseURL.appendingPathComponent("v1/search")
        var urlRequest = URLRequest(url: searchURL)
        urlRequest.httpMethod = "POST"
        urlRequest.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        Logger.shared.log(.nebula, "POST \(searchURL.absoluteString)")

        do {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            Logger.shared.log(.nebula, "Encoding error: \(error.localizedDescription)")
            completion(.failure(error))
            return
        }

        session.dataTask(with: urlRequest) { data, response, error in
            if let error = error {
                Logger.shared.log(.nebula, "Request failed: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                Logger.shared.log(.nebula, "HTTP \(httpResponse.statusCode)")
                
                // Accept all 2xx status codes as success (200-299)
                if !(200...299).contains(httpResponse.statusCode) {
                    if let data = data, let errorBody = String(data: data, encoding: .utf8) {
                        let preview = errorBody.count > 300 ? String(errorBody.prefix(300)) + "..." : errorBody
                        Logger.shared.log(.nebula, "Error (\(httpResponse.statusCode)): \(preview)")
                        
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

