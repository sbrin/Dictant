//
//  SimpleSpeechViewModel.swift
//  Dictant
//

import SwiftUI
import Combine
import AVFoundation
import AppKit
import CoreGraphics
import ApplicationServices
@preconcurrency import UserNotifications

@MainActor
class SimpleSpeechViewModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = SimpleSpeechViewModel()
    
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var transcriptionText = ""
    @Published var recordingDuration = "00:00"
    @Published var error: String?
    @Published var recordings: [Recording] = []
    
    private var audioRecorder: AVAudioRecorder?
    private let simpleSpeechService = SimpleSpeechService.shared
    private let settingsManager = SettingsManager.shared
    
    private var audioFileURL: URL?
    private var currentRecordingId: UUID?
    private var currentRecordingStartDate: Date?
    private var durationTimer: Timer?
    private var transcriptionTask: Task<Void, Never>?
    
    /// Directory for storing recordings
    nonisolated static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "ilin.pt.Dictant"
        let recordingsDir = appSupport.appendingPathComponent(bundleId).appendingPathComponent("Recordings")
        
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        
        return recordingsDir
    }
    
    override init() {
        super.init()
        loadRecordings()
    }
    
    func startRecording() async {
        if !settingsManager.isAPIKeyValid {
            settingsManager.selectedTab = "Processing"
            StatusItemManager.shared.showSettingsWindow()
            
            let content = UNMutableNotificationContent()
            content.title = "OpenAI API Key Required"
            content.body = "Please set up your OpenAI API key in the settings to start transcribing."
            content.sound = .default
            
            let request = UNNotificationRequest(identifier: "APIKeyRequired", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            return
        }
        
        let hasPermission = await AudioPermissionManager.shared.requestMicrophonePermission()
        guard hasPermission else {
            self.error = AudioPermissionManager.shared.error ?? "Microphone permission denied. Please enable access in System Settings."
            
            let content = UNMutableNotificationContent()
            content.title = "Microphone Access Required"
            content.body = "Dictant cannot start recording without microphone permission. Enable access in System Settings → Privacy & Security → Microphone."
            content.sound = .default
            content.categoryIdentifier = "MICROPHONE_PERMISSION"
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            return
        }
        
        let recordingId = UUID()
        let startDate = Date()
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = dateFormatter.string(from: startDate).replacingOccurrences(of: ":", with: "-")
        let fileName = "\(recordingId.uuidString)_\(timestamp).m4a"
        let fileURL = SimpleSpeechViewModel.recordingsDirectory.appendingPathComponent(fileName)
        
        self.audioFileURL = fileURL
        self.currentRecordingId = recordingId
        self.currentRecordingStartDate = startDate
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.delegate = self
            if recorder.record() {
                self.isRecording = true
                self.error = nil
                self.transcriptionText = "" 
                self.recordingDuration = "00:00"
                
                durationTimer?.invalidate()
                let dTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self, let start = self.currentRecordingStartDate else { return }
                        let elapsed = Date().timeIntervalSince(start)
                        let minutes = Int(elapsed) / 60
                        let seconds = Int(elapsed) % 60
                        self.recordingDuration = String(format: "%02d:%02d", minutes, seconds)
                    }
                }
                RunLoop.main.add(dTimer, forMode: .common)
                durationTimer = dTimer
                
                #if DEBUG
                print("SimpleSpeechViewModel: Recording started at \(fileURL.path)")
                #endif
            } else {
                self.error = "Failed to start recording"
            }
            self.audioRecorder = recorder
        } catch {
            self.error = "Failed to create recorder: \(error.localizedDescription)"
        }
    }
    
    func stopRecording() async {
        guard let recorder = audioRecorder, recorder.isRecording else {
            return
        }
        
        durationTimer?.invalidate()
        durationTimer = nil
        
        let recordingURL = recorder.url
        let recordingId = currentRecordingId ?? UUID()
        let startDate = currentRecordingStartDate ?? Date()
        
        let recordedDuration = Date().timeIntervalSince(startDate)
        recorder.stop()
        self.isRecording = false
        
        #if DEBUG
        print(String(format: "SimpleSpeechViewModel: Recording stopped. Duration: %.2fs, File: %@", recordedDuration, recordingURL.path))
        #endif
        if recordedDuration < 2 {
            try? FileManager.default.removeItem(at: recordingURL)
            self.audioRecorder = nil
            self.currentRecordingId = nil
            self.currentRecordingStartDate = nil
            self.recordingDuration = "00:00"
            self.transcriptionTask = nil
            #if DEBUG
            print(String(format: "SimpleSpeechViewModel: Recording discarded due to short duration (%.2fs)", recordedDuration))
            #endif
            return
        }
        
        guard isAudioFileUsable(recordingURL) else {
            self.error = "Recorded audio file is missing or empty."
            self.currentRecordingId = nil
            self.currentRecordingStartDate = nil
            self.recordingDuration = "00:00"
            
            let content = UNMutableNotificationContent()
            content.title = "Recording Failed"
            content.body = "The recorded audio file could not be saved. Please try again."
            content.sound = .default
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            return
        }
        
        self.isProcessing = true
        transcriptionTask = Task {
            var transcriptionURL = recordingURL
            var transcriptionDuration = recordedDuration
            
            // Process to remove silence
            do {
                #if DEBUG
                print("SimpleSpeechViewModel: Starting silence removal...")
                #endif
                let processedUrl = try await AudioProcessor.shared.processAudio(at: recordingURL)
                if isAudioFileUsable(processedUrl) {
                    transcriptionURL = processedUrl
                } else {
                    if processedUrl != recordingURL, isTemporaryFile(processedUrl) {
                        try? FileManager.default.removeItem(at: processedUrl)
                    }
                    #if DEBUG
                    print("SimpleSpeechViewModel: Processed audio file is missing or empty. Using original file.")
                    #endif
                }
                
                // Recalculate duration
                if let assetDuration = try? await AVAsset(url: transcriptionURL).load(.duration).seconds {
                    transcriptionDuration = assetDuration
                    #if DEBUG
                    print("SimpleSpeechViewModel: Silence removed. Original: \(recordedDuration)s, New: \(assetDuration)s")
                    #endif
                }
            } catch {
                #if DEBUG
                print("SimpleSpeechViewModel: Audio processing failed: \(error). Using original file.")
                #endif
            }
            
            // Final duration check
            if transcriptionDuration < 1.0 {
                #if DEBUG
                print("SimpleSpeechViewModel: Final audio duration (%.2fs) is too short. Aborting transcription.", transcriptionDuration)
                #endif
                self.isProcessing = false
                self.currentRecordingId = nil
                self.currentRecordingStartDate = nil
                self.transcriptionTask = nil
                try? FileManager.default.removeItem(at: recordingURL)
                if transcriptionURL != recordingURL, isTemporaryFile(transcriptionURL) {
                    try? FileManager.default.removeItem(at: transcriptionURL)
                }
                
                // Notify user
                let content = UNMutableNotificationContent()
                content.title = "Input too short"
                content.body = "It was too quiet. Please check your microphone settings and try again."
                content.sound = .default
                
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
                
                return
            }
            
            await processAudioFile(
                recordingURL: recordingURL,
                transcriptionURL: transcriptionURL,
                recordingId: recordingId,
                startDate: startDate,
                duration: recordedDuration
            )
        }
    }
    
    func transcribeExistingRecording(_ recording: Recording) async {
        guard !isProcessing else { return }
        
        self.isProcessing = true
        transcriptionTask = Task {
            await processAudioFile(
                recordingURL: recording.fileURL,
                transcriptionURL: recording.fileURL,
                recordingId: recording.id,
                startDate: recording.startDate,
                duration: recording.duration ?? 0,
                isExisting: true
            )
        }
    }
    
    private func processAudioFile(
        recordingURL: URL,
        transcriptionURL: URL,
        recordingId: UUID,
        startDate: Date,
        duration: TimeInterval,
        isExisting: Bool = false
    ) async {
        var cleanupURL: URL?
        defer {
            self.isProcessing = false
            self.transcriptionTask = nil
            if !isExisting {
                self.currentRecordingId = nil
                self.currentRecordingStartDate = nil
            }
            if let cleanupURL = cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
        
        guard let transcriptionURLToUse = resolveTranscriptionURL(preferred: transcriptionURL, fallback: recordingURL) else {
            self.error = "Audio file is missing or empty."
            
            let content = UNMutableNotificationContent()
            content.title = "Recording Missing"
            content.body = "The audio file could not be found. Please try again."
            content.sound = .default
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            return
        }
        
        let recordingURLToSave = ensureRecordingFile(for: recordingURL, fallbackURL: transcriptionURLToUse)
        if transcriptionURLToUse != recordingURL, isTemporaryFile(transcriptionURLToUse) {
            cleanupURL = transcriptionURLToUse
        }
        
        var finalTranscription: String?
        
        do {
            #if DEBUG
            print("SimpleSpeechViewModel: Starting transcription for file: \(transcriptionURLToUse.lastPathComponent)")
            #endif
            var result = try await simpleSpeechService.transcribe(audioFileURL: transcriptionURLToUse)
            
            if Task.isCancelled { return }
            
            // Add ChatGPT processing if enabled
            if settingsManager.processWithChatGPT && !settingsManager.chatGPTSystemPrompt.isEmpty {
                #if DEBUG
                print("SimpleSpeechViewModel: Processing with ChatGPT. Input length: \(result.count)")
                #endif
                result = try await simpleSpeechService.processWithChatGPT(text: result, systemPrompt: settingsManager.chatGPTSystemPrompt)
            }
            
            if Task.isCancelled { return }
            
            self.transcriptionText = result
            finalTranscription = result
            #if DEBUG
            print("SimpleSpeechViewModel: Processing complete. Result: \(result)")
            #endif
            
            let notificationBody = await handleTranscriptionResult(
                result,
                allowClipboardActions: !isExisting
            )
            
            let content = UNMutableNotificationContent()
            content.title = isExisting ? "Re-transcription Complete" : "Transcription Complete"
            content.body = notificationBody
            content.sound = .default
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        } catch {
            if Task.isCancelled { return }
            
            #if DEBUG
            print("SimpleSpeechViewModel: Error during processing: \(error)")
            #endif
            
            if let serviceError = error as? SimpleSpeechService.ServiceError, serviceError == .invalidAPIKey {
                self.error = "Invalid OpenAI API Key. Please check your settings."
                
                settingsManager.isAPIKeyValid = false
                settingsManager.selectedTab = "Processing"
                StatusItemManager.shared.showSettingsWindow()
                
                let content = UNMutableNotificationContent()
                content.title = "Invalid OpenAI API Key"
                content.body = "The API key provided appears to be invalid or was rejected. Please check your settings."
                content.sound = .default
                
                let request = UNNotificationRequest(identifier: "InvalidAPIKey", content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            } else {
                self.error = "Transcription failed: \(error.localizedDescription)"
                
                let content = UNMutableNotificationContent()
                content.title = "Transcription Failed"
                content.body = "An error occurred during transcription. The recording has been saved for a retry attempt."
                content.sound = .default
                
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
        
        if isExisting {
            if let index = recordings.firstIndex(where: { $0.id == recordingId }) {
                recordings[index].transcription = finalTranscription
                saveRecordings()
            }
        } else {
            if let recordingURLToSave {
                let newRecording = Recording(id: recordingId, startDate: startDate, relativeFilePath: recordingURLToSave.lastPathComponent, duration: duration, transcription: finalTranscription)
                self.recordings.insert(newRecording, at: 0)
                saveRecordings()
            } else if finalTranscription != nil {
                let content = UNMutableNotificationContent()
                content.title = "Recording Not Saved"
                content.body = "Transcription finished, but the audio file could not be saved to history."
                content.sound = .default
                
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }
    
    func cancelProcessing() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isProcessing = false
        currentRecordingId = nil
        currentRecordingStartDate = nil
    }
    
    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }
    
    func clearTranscription() {
        transcriptionText = ""
        error = nil
    }
    
    func deleteRecording(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings.remove(at: index)
            try? FileManager.default.removeItem(at: recording.fileURL)
            saveRecordings()
        }
    }
    
    func clearHistory() {
        for recording in recordings {
            try? FileManager.default.removeItem(at: recording.fileURL)
        }
        recordings.removeAll()
        saveRecordings()
    }
    
    func showInFinder(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.fileURL])
    }
    
    func copyTranscription(_ recording: Recording) {
        guard let transcription = recording.transcription, !transcription.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcription, forType: .string)
    }
    
    func updateTranscription(for recordingId: UUID, transcription: String) {
        guard let index = recordings.firstIndex(where: { $0.id == recordingId }) else { return }
        recordings[index].transcription = transcription
        saveRecordings()
    }
    
    private func saveRecordings() {
        do {
            let data = try JSONEncoder().encode(recordings)
            let fileURL = SimpleSpeechViewModel.recordingsDirectory.appendingPathComponent("recordings.json")
            try data.write(to: fileURL)
        } catch {
            print("Failed to save recordings: \(error)")
        }
    }
    
    private func loadRecordings() {
        let fileURL = SimpleSpeechViewModel.recordingsDirectory.appendingPathComponent("recordings.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: fileURL)
            self.recordings = try JSONDecoder().decode([Recording].self, from: data)
        } catch {
            print("Failed to load recordings: \(error)")
        }
    }
    
    private func handleTranscriptionResult(_ transcription: String, allowClipboardActions: Bool = true) async -> String {
        guard allowClipboardActions else {
            return "Your recording is successfully transcribed and saved to history."
        }
        
        let shouldCopy = settingsManager.copyTranscribedTextToClipboard
        let shouldPaste = settingsManager.pasteTranscribedTextIntoActiveInput
        let canPaste = shouldPaste && ensureAccessibilityPermissionForPasting()
        
        guard shouldCopy || canPaste else {
            return "Your recording is successfully transcribed."
        }
        
        let pasteboard = NSPasteboard.general
        var previousItems: [NSPasteboardItem]?
        
        if canPaste && !shouldCopy {
            previousItems = pasteboard.pasteboardItems
        }
        
        pasteboard.clearContents()
        pasteboard.setString(transcription, forType: .string)
        
        if canPaste {
            pasteClipboardIntoActiveApp()
        }
        
        if !shouldCopy {
            // Wait a tiny bit for the OS to process the paste event before clearing/restoring the clipper
            try? await Task.sleep(nanoseconds: 200 * 1_000_000) // 200ms
            
            pasteboard.clearContents()
            if let items = previousItems, !items.isEmpty {
                pasteboard.writeObjects(items)
            }
        }
        
        let actionText = transcriptionActionDescription(copyEnabled: shouldCopy, pasteEnabled: canPaste)
        if actionText.isEmpty {
            return "Your recording is successfully transcribed."
        } else {
            return "Your recording is successfully transcribed. The result was \(actionText)."
        }
    }
    
    private func transcriptionActionDescription(copyEnabled: Bool, pasteEnabled: Bool) -> String {
        switch (copyEnabled, pasteEnabled) {
        case (true, true):
            return "copied to clipboard and pasted into active input"
        case (true, false):
            return "copied to clipboard"
        case (false, true):
            return "pasted into active input"
        default:
            return ""
        }
    }
    
    private func ensureAccessibilityPermissionForPasting() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        
        let options: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        
        if !isTrusted {
            error = "Accessibility access is required to paste transcriptions automatically. Enable it in System Settings."
        }
        
        return isTrusted
    }
    
    private func pasteClipboardIntoActiveApp() {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            print("SimpleSpeechViewModel: Unable to create event source for paste action")
            return
        }
        
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
    
    private func isAudioFileUsable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber {
            return size.int64Value > 0
        }
        return true
    }
    
    private func resolveTranscriptionURL(preferred: URL, fallback: URL) -> URL? {
        if isAudioFileUsable(preferred) {
            return preferred
        }
        if isAudioFileUsable(fallback) {
            return fallback
        }
        return nil
    }
    
    private func ensureRecordingFile(for recordingURL: URL, fallbackURL: URL) -> URL? {
        if isAudioFileUsable(recordingURL) {
            return recordingURL
        }
        guard recordingURL != fallbackURL, isAudioFileUsable(fallbackURL) else { return nil }
        
        do {
            let directory = recordingURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                try FileManager.default.removeItem(at: recordingURL)
            }
            try FileManager.default.copyItem(at: fallbackURL, to: recordingURL)
            return isAudioFileUsable(recordingURL) ? recordingURL : nil
        } catch {
            #if DEBUG
            print("SimpleSpeechViewModel: Failed to save recording file: \(error)")
            #endif
            return nil
        }
    }
    
    private func isTemporaryFile(_ url: URL) -> Bool {
        url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
    }
}
