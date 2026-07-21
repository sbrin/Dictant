//
//  ProcessingView.swift
//  Dictant
//

import SwiftUI
import AppKit

struct ProcessingView: View {
    @StateObject private var settingsManager = SettingsManager.shared
    @State private var tempAPIKey = ""
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadingError: String?
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

                HStack {
                    Text("Transcription Model")
                        .font(.headline)

                    Spacer()

                    Picker("Transcription Model", selection: $settingsManager.selectedTranscriptionModel) {
                        ForEach(SettingsManager.transcriptionModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
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
                        HStack {
                            Text("Model")
                                .font(.headline)

                            Spacer()

                            if isLoadingModels {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Picker("Model", selection: $settingsManager.selectedChatGPTModel) {
                                ForEach(displayedModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 250)

                            Button {
                                Task {
                                    await loadAvailableModels()
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isLoadingModels)
                            .help("Refresh available models")
                        }

                        if let modelLoadingError {
                            Text(modelLoadingError)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

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
                        
                        Text("This will process the transcribed text using \(settingsManager.selectedChatGPTModel).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(20)
        .task(id: settingsManager.openAIAPIKey) {
            await loadAvailableModels()
        }
    }

    private var displayedModels: [String] {
        if availableModels.isEmpty {
            return [settingsManager.selectedChatGPTModel]
        }
        return availableModels
    }

    private func loadAvailableModels() async {
        guard settingsManager.isAPIKeyValid else {
            availableModels = []
            modelLoadingError = nil
            return
        }

        isLoadingModels = true
        modelLoadingError = nil
        defer { isLoadingModels = false }

        do {
            let models = try await SimpleSpeechService.shared.fetchAvailableChatModels()
            guard !models.isEmpty else {
                availableModels = []
                modelLoadingError = "No compatible text models are available for this API key."
                return
            }

            if !models.contains(settingsManager.selectedChatGPTModel) {
                settingsManager.selectedChatGPTModel = models.contains(SettingsManager.defaultChatGPTModel)
                    ? SettingsManager.defaultChatGPTModel
                    : models[0]
            }
            availableModels = models
        } catch SimpleSpeechService.ServiceError.invalidAPIKey {
            availableModels = []
            modelLoadingError = "The API key could not load available models."
        } catch SimpleSpeechService.ServiceError.apiError(let message) {
            availableModels = []
            modelLoadingError = "Could not load models: \(message)"
        } catch {
            availableModels = []
            modelLoadingError = "Could not load available models."
        }
    }
}
