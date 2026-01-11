//
//  SimpleSpeechService.swift
//  Dictant
//

import Foundation
import Combine

/// Service to handle standard OpenAI Whisper API transcriptions (non-realtime).
@MainActor
class SimpleSpeechService {
    static let shared = SimpleSpeechService()
    static let maxAudioPayloadBytes: Int64 = 5_000 * 1024

    private static let transcriptionRequestTimeout: TimeInterval = 300.0
    private static let transcriptionResourceTimeout: TimeInterval = 1200.0
    
    private let settingsManager = SettingsManager.shared
    private lazy var transcriptionSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.transcriptionRequestTimeout
        config.timeoutIntervalForResource = Self.transcriptionResourceTimeout
        return URLSession(configuration: config)
    }()
    
    enum ServiceError: Error, Equatable {
        case invalidAPIKey
        case invalidURL
        case networkError(String)
        case invalidResponse
        case apiError(String)
        case encodingError
        
        static func == (lhs: ServiceError, rhs: ServiceError) -> Bool {
            switch (lhs, rhs) {
            case (.invalidAPIKey, .invalidAPIKey),
                 (.invalidURL, .invalidURL),
                 (.invalidResponse, .invalidResponse),
                 (.encodingError, .encodingError):
                return true
            case (.networkError(let a), .networkError(let b)):
                return a == b
            case (.apiError(let a), .apiError(let b)):
                return a == b
            default:
                return false
            }
        }
    }
    
    struct TranscriptionConfiguration: Encodable {
        let model: String
        let language: String?
        let prompt: String?
        let temperature: Double?
        
        init(model: String = "whisper-1",
             language: String? = nil,
             prompt: String? = nil,
             temperature: Double? = nil) {
            self.model = model
            self.language = language
            self.prompt = prompt
            self.temperature = temperature
        }
    }
    
    func transcribe(audioFileURL: URL, configuration: TranscriptionConfiguration = TranscriptionConfiguration()) async throws -> String {
        guard !settingsManager.openAIAPIKey.isEmpty else {
            throw ServiceError.invalidAPIKey
        }
        
        #if DEBUG
        print("SimpleSpeechService: Sending transcription request for \(audioFileURL.lastPathComponent)")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: audioFileURL.path),
           let size = attributes[.size] as? Int64 {
            print("SimpleSpeechService: Audio file size: \(size) bytes")
        }
        #endif
        
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw ServiceError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settingsManager.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioFileURL)
        } catch {
            throw ServiceError.networkError(error.localizedDescription)
        }
        
        let body = createMultipartBody(boundary: boundary, 
                                     audioData: audioData, 
                                     filename: audioFileURL.lastPathComponent, 
                                     configuration: configuration)
        request.httpBody = body
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transcriptionSession.data(for: request)
        } catch {
            throw ServiceError.networkError(error.localizedDescription)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            if httpResponse.statusCode == 401 {
                throw ServiceError.invalidAPIKey
            }
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorDict = errorJson["error"] as? [String: Any],
               let message = errorDict["message"] as? String {
                #if DEBUG
                print("SimpleSpeechService: API Error (\(httpResponse.statusCode)): \(message)")
                #endif
                throw ServiceError.apiError(message)
            }
            let bodyString = String(data: data, encoding: .utf8) ?? "No body"
            #if DEBUG
            print("SimpleSpeechService: API Error (\(httpResponse.statusCode)): \(bodyString)")
            #endif
            throw ServiceError.apiError("Status code: \(httpResponse.statusCode) - \(bodyString)")
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String {
                #if DEBUG
                print("SimpleSpeechService: Transcription response received. Text length: \(text.count)")
                #endif
                return text
            }
            throw ServiceError.invalidResponse
        } catch {
            throw ServiceError.networkError(error.localizedDescription)
        }
    }
    
    func processWithChatGPT(text: String, systemPrompt: String) async throws -> String {
        guard !settingsManager.openAIAPIKey.isEmpty else {
            throw ServiceError.invalidAPIKey
        }
        
        #if DEBUG
        print("SimpleSpeechService: Sending ChatGPT request")
        print("SimpleSpeechService: System Prompt: \(systemPrompt)")
        print("SimpleSpeechService: User Text: \(text)")
        #endif
        
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw ServiceError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settingsManager.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Structures input as an array of messages
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": text]
        ]
        
        let body: [String: Any] = [
            "model": "gpt-4o",
            "messages": messages,
            "temperature": 0.7
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(error.localizedDescription)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
             if httpResponse.statusCode == 401 {
                 throw ServiceError.invalidAPIKey
             }
             if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let errorDict = errorJson["error"] as? [String: Any],
                let message = errorDict["message"] as? String {
                 #if DEBUG
                 print("SimpleSpeechService: ChatGPT API Error (\(httpResponse.statusCode)): \(message)")
                 #endif
                 throw ServiceError.apiError(message)
             }
             let bodyString = String(data: data, encoding: .utf8) ?? "No body"
             #if DEBUG
             print("SimpleSpeechService: ChatGPT API Error (\(httpResponse.statusCode)): \(bodyString)")
             #endif
             throw ServiceError.apiError("Status code: \(httpResponse.statusCode) - \(bodyString)")
        }
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            
            let result = content.trimmingCharacters(in: .whitespacesAndNewlines)
            #if DEBUG
            print("SimpleSpeechService: ChatGPT response received. Result: \(result)")
            #endif
            return result
        }
        
        throw ServiceError.invalidResponse
    }
    
    private func createMultipartBody(boundary: String, audioData: Data, filename: String, configuration: TranscriptionConfiguration) -> Data {
        var body = Data()
        let lineBreak = "\r\n"
        
        func append(_ string: String) {
            if let data = string.data(using: .utf8) {
                body.append(data)
            }
        }
        
        let mimeType = filename.hasSuffix(".wav") ? "audio/wav" : "audio/m4a"
        
        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(lineBreak)")
        append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)")
        body.append(audioData)
        append("\(lineBreak)")
        
        let mirror = Mirror(reflecting: configuration)
        for child in mirror.children {
            guard let label = child.label else { continue }
            
            let value: String?
            if let optionalValue = child.value as? OptionalProtocol {
                if optionalValue.isNil { continue }
                value = "\(optionalValue.unwrap())"
            } else {
                value = "\(child.value)"
            }
            
            if let existingValue = value {
                var key = label
                if key == "responseFormat" { key = "response_format" }
                
                append("--\(boundary)\(lineBreak)")
                append("Content-Disposition: form-data; name=\"\(key)\"\(lineBreak)\(lineBreak)")
                append("\(existingValue)\(lineBreak)")
            }
        }
        
        append("--\(boundary)--\(lineBreak)")
        
        return body
    }
}

fileprivate protocol OptionalProtocol {
    var isNil: Bool { get }
    func unwrap() -> Any
}

extension Optional: OptionalProtocol {
    var isNil: Bool { return self == nil }
    func unwrap() -> Any { return self! }
}
