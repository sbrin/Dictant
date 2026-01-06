//
//  SettingsManager.swift
//  Dictant
//

import Foundation
import Security
import ServiceManagement

@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    @Published var openAIAPIKey: String = ""
    @Published var isAPIKeyValid: Bool = false
    @Published var selectedTab: String
    @Published var copyTranscribedTextToClipboard: Bool {
        didSet {
            UserDefaults.standard.set(copyTranscribedTextToClipboard, forKey: copyPreferenceKey)
        }
    }
    @Published var pasteTranscribedTextIntoActiveInput: Bool {
        didSet {
            UserDefaults.standard.set(pasteTranscribedTextIntoActiveInput, forKey: pastePreferenceKey)
        }
    }
    @Published var processWithChatGPT: Bool {
        didSet {
            UserDefaults.standard.set(processWithChatGPT, forKey: processWithChatGPTKey)
        }
    }
    @Published var chatGPTSystemPrompt: String {
        didSet {
            UserDefaults.standard.set(chatGPTSystemPrompt, forKey: chatGPTSystemPromptKey)
        }
    }
    @Published var holdRightCommandForPTT: Bool {
        didSet {
            UserDefaults.standard.set(holdRightCommandForPTT, forKey: holdRightCommandKey)
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            if launchAtLogin != (SMAppService.mainApp.status == .enabled) {
                do {
                    if launchAtLogin {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("Failed to update login item status: \(error)")
                }
            }
        }
    }
    
    private let serviceName = "com.Dictant.openai"
    private let accountName = "api-key"
    private let copyPreferenceKey = "copyTranscribedTextToClipboard"
    private let pastePreferenceKey = "pasteTranscribedTextIntoActiveInput"
    private let processWithChatGPTKey = "processWithChatGPT"
    private let chatGPTSystemPromptKey = "chatGPTSystemPrompt"
    private let holdRightCommandKey = "holdRightCommandForPTT"
    
    private init() {
        let defaults = UserDefaults.standard
        selectedTab = "General"
        copyTranscribedTextToClipboard = defaults.object(forKey: copyPreferenceKey) as? Bool ?? true
        pasteTranscribedTextIntoActiveInput = defaults.object(forKey: pastePreferenceKey) as? Bool ?? true
        processWithChatGPT = defaults.object(forKey: processWithChatGPTKey) as? Bool ?? false
        chatGPTSystemPrompt = defaults.string(forKey: chatGPTSystemPromptKey) ?? "Polish the transcriptions for clarity and conciseness while maintaining the original tone."
        holdRightCommandForPTT = defaults.object(forKey: holdRightCommandKey) as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loadAPIKey()
        
        #if DEBUG
        logSettings()
        #endif
    }
    
    #if DEBUG
    private func logSettings() {
        print("--- Dictant Settings ---")
        print("API Key Valid: \(isAPIKeyValid)")
        print("Copy to Clipboard: \(copyTranscribedTextToClipboard)")
        print("Paste to Active Input: \(pasteTranscribedTextIntoActiveInput)")
        print("Process with ChatGPT: \(processWithChatGPT)")
        if processWithChatGPT {
            print("ChatGPT System Prompt: \(chatGPTSystemPrompt)")
        }
        print("---------------------------")
    }
    #endif
    
    // MARK: - Keychain Operations
    
    private func loadAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            openAIAPIKey = key
            validateAPIKey(key)
        }
    }
    
    func saveAPIKey(_ key: String) {
        // Remove existing key first
        deleteAPIKey()
        
        guard let data = key.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status == errSecSuccess {
            openAIAPIKey = key
            validateAPIKey(key)
        } else {
            print("Failed to save API key to keychain: \(status)")
        }
    }
    
    private func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]
        
        SecItemDelete(query as CFDictionary)
    }
    
    // MARK: - API Key Validation
    
    private func validateAPIKey(_ key: String) {
        // Basic validation: OpenAI API keys start with "sk-" and are typically 51 characters long
        let isValid = key.hasPrefix("sk-") && key.count >= 20
        isAPIKeyValid = isValid
    }
    
    func updateAPIKey(_ key: String) {
        saveAPIKey(key)
    }
    
    func clearAPIKey() {
        deleteAPIKey()
        openAIAPIKey = ""
        isAPIKeyValid = false
    }
}
