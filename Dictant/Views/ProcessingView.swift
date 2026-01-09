//
//  ProcessingView.swift
//  Dictant
//

import SwiftUI
import AppKit

struct ProcessingView: View {
    @StateObject private var settingsManager = SettingsManager.shared
    @State private var tempAPIKey = ""
    private let apiKeyHelpURL = URL(string: "https://platform.openai.com/account/api-keys")!
    
    private var hasUnsavedChanges: Bool { tempAPIKey != settingsManager.openAIAPIKey }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OpenAI Configuration")
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("API Key")
                        .font(.headline)
                    SecureField("Enter your OpenAI API key", text: $tempAPIKey)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .onAppear {
                            tempAPIKey = settingsManager.openAIAPIKey
                        }
                    Spacer()
                    if settingsManager.isAPIKeyValid && !tempAPIKey.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
                
                Text("Your API key is stored securely in the macOS Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if settingsManager.openAIAPIKey.isEmpty || !settingsManager.isAPIKeyValid {
                    HStack(spacing: 4) {
                        Text("No valid API key found. Create one at")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Link("https://platform.openai.com/account/api-keys", destination: apiKeyHelpURL)
                            .font(.caption)
                    }
                }
                
                if hasUnsavedChanges && !tempAPIKey.isEmpty {
                    HStack {
                        Button("Save") {
                            settingsManager.updateAPIKey(tempAPIKey)
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                SettingToggleRow(
                    title: "Process results with ChatGPT",
                    isOn: $settingsManager.processWithChatGPT
                )
                .disabled(!settingsManager.isAPIKeyValid)
                
                if !settingsManager.isAPIKeyValid {
                    Text("API key is required to use ChatGPT processing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }
                
                if settingsManager.processWithChatGPT && settingsManager.isAPIKeyValid {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System Prompt")
                            .font(.headline)
                        
                        TextEditor(text: $settingsManager.chatGPTSystemPrompt)
                            .frame(height: 100)
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        
                        Text("This will be used to process the transcribed text using ChatGPT (gpt-5)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(20)
    }
}
