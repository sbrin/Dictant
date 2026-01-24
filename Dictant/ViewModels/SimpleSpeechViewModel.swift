//
//  SimpleSpeechViewModel.swift
//  Dictant
//

import SwiftUI
import Combine
import AVFoundation
import AppKit
import UniformTypeIdentifiers
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
    @Published var processingRecordingIds: Set<UUID> = []
    
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
        
        let fileURL = makeRecordingFileURL(
            recordingId: recordingId,
            startDate: startDate,
            fileExtension: "m4a"
        )
        
        self.audioFileURL = fileURL
        self.currentRecordingId = recordingId
        self.currentRecordingStartDate = startDate
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: Constants.Audio.sampleRate,
            AVNumberOfChannelsKey: Constants.Audio.channelCount,
            AVEncoderBitRateKey: Constants.Audio.bitRate,
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
                let dTimer = Timer(timeInterval: Constants.UI.timerInterval, repeats: true) { [weak self] _ in
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
        if recordedDuration < Constants.Audio.minRecordingDuration {
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
        
        runTranscriptionFlow(
            sourceURL: recordingURL,
            recordingURL: recordingURL,
            recordingId: recordingId,
            startDate: startDate,
            originalDuration: recordedDuration,
            context: "recording",
            tooShortMessage: "It was too quiet. Please check your microphone settings and try again.",
            cleanupURLs: [recordingURL]
        ) {
            self.isProcessing = false
            self.currentRecordingId = nil
            self.currentRecordingStartDate = nil
            self.transcriptionTask = nil
        }
    }

    func loadAudioFile() async {
        guard !isRecording && !isProcessing else { return }
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

        let panel = NSOpenPanel()
        panel.title = "Load Audio File"
        panel.prompt = "Load"
        panel.message = "Choose an audio file to transcribe."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let allowedExtensions = ["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm"]
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        guard isAudioFileUsable(selectedURL) else {
            self.error = "Selected audio file is missing or empty."

            let content = UNMutableNotificationContent()
            content.title = "Invalid Audio File"
            content.body = "The selected audio file could not be opened. Please choose another file."
            content.sound = .default

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            return
        }

        self.error = nil
        self.transcriptionText = ""
        let recordingId = UUID()
        let startDate = Date()

        let fileExtension = selectedURL.pathExtension.isEmpty ? "m4a" : selectedURL.pathExtension
        let recordingURL = makeRecordingFileURL(
            recordingId: recordingId,
            startDate: startDate,
            fileExtension: fileExtension
        )

        var originalDuration: TimeInterval = 0
        var didCopyOriginal = false

        if let assetDuration = try? await AVAsset(url: selectedURL).load(.duration).seconds {
            originalDuration = assetDuration
        }
        do {
            try FileManager.default.copyItem(at: selectedURL, to: recordingURL)
            didCopyOriginal = true
        } catch {
            #if DEBUG
            print("SimpleSpeechViewModel: Failed to copy original file into history: \(error)")
            #endif
        }

        var cleanupURLs: [URL] = []
        if didCopyOriginal {
            cleanupURLs.append(recordingURL)
        }

        runTranscriptionFlow(
            sourceURL: selectedURL,
            recordingURL: recordingURL,
            recordingId: recordingId,
            startDate: startDate,
            originalDuration: originalDuration,
            context: "loaded file",
            tooShortMessage: "It was too quiet. Please check your audio and try again.",
            cleanupURLs: cleanupURLs
        ) {
            self.isProcessing = false
            self.transcriptionTask = nil
        }
    }

    private func runTranscriptionFlow(
        sourceURL: URL,
        recordingURL: URL,
        recordingId: UUID,
        startDate: Date,
        originalDuration: TimeInterval,
        context: String,
        tooShortMessage: String,
        cleanupURLs: [URL],
        onEarlyExit: @escaping () -> Void
    ) {
        self.isProcessing = true
        transcriptionTask = Task {
            let prepared = await prepareAudioForTranscription(
                sourceURL: sourceURL,
                originalDuration: originalDuration,
                context: context
            )
            let transcriptionURL = prepared.transcriptionURL
            let transcriptionDuration = prepared.transcriptionDuration

            var finalCleanupURLs = cleanupURLs
            if transcriptionURL != sourceURL, isTemporaryFile(transcriptionURL) {
                finalCleanupURLs.append(transcriptionURL)
            }

            let didAbort = await handleTooShortTranscription(
                duration: transcriptionDuration,
                notificationBody: tooShortMessage,
                cleanupURLs: finalCleanupURLs
            ) {
                onEarlyExit()
            }
            if didAbort { return }

            await processAudioFile(
                recordingURL: recordingURL,
                transcriptionURL: transcriptionURL,
                recordingId: recordingId,
                startDate: startDate,
                duration: originalDuration,
                processedDuration: transcriptionDuration
            )
        }
    }

    private func prepareAudioForTranscription(
        sourceURL: URL,
        originalDuration: TimeInterval,
        context: String
    ) async -> (transcriptionURL: URL, transcriptionDuration: TimeInterval) {
        var transcriptionURL = sourceURL
        var transcriptionDuration = originalDuration

        do {
            #if DEBUG
            print("SimpleSpeechViewModel: Starting silence removal for \(context)...")
            #endif
            let processedUrl = try await AudioProcessor.shared.processAudio(at: sourceURL)
            if isAudioFileUsable(processedUrl) {
                transcriptionURL = processedUrl
            } else {
                if processedUrl != sourceURL, isTemporaryFile(processedUrl) {
                    try? FileManager.default.removeItem(at: processedUrl)
                }
                #if DEBUG
                print("SimpleSpeechViewModel: Processed audio file is missing or empty. Using original file.")
                #endif
            }

            if let assetDuration = try? await AVAsset(url: transcriptionURL).load(.duration).seconds,
               assetDuration.isFinite {
                transcriptionDuration = assetDuration
                #if DEBUG
                print("SimpleSpeechViewModel: Silence removed. Original: \(originalDuration)s, New: \(assetDuration)s")
                #endif
            }
        } catch {
            #if DEBUG
            print("SimpleSpeechViewModel: Audio processing failed: \(error). Using original file.")
            #endif
        }

        return (transcriptionURL, transcriptionDuration)
    }

    private func isTooShortTranscriptionDuration(_ duration: TimeInterval) -> Bool {
        duration.isFinite && duration > 0 && duration < Constants.Audio.minSegmentDuration
    }

    private func handleTooShortTranscription(
        duration: TimeInterval,
        notificationBody: String,
        cleanupURLs: [URL],
        onEarlyExit: () -> Void
    ) async -> Bool {
        guard isTooShortTranscriptionDuration(duration) else { return false }

        #if DEBUG
        print(String(format: "SimpleSpeechViewModel: Final audio duration (%.2fs) is too short. Aborting transcription.", duration))
        #endif

        onEarlyExit()

        for url in Set(cleanupURLs) {
            try? FileManager.default.removeItem(at: url)
        }

        let content = UNMutableNotificationContent()
        content.title = "Input too short"
        content.body = notificationBody
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)

        return true
    }

    private func makeRecordingFileURL(
        recordingId: UUID,
        startDate: Date,
        fileExtension: String
    ) -> URL {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = dateFormatter.string(from: startDate).replacingOccurrences(of: ":", with: "-")
        let fileName = "\(recordingId.uuidString)_\(timestamp).\(fileExtension)"
        return SimpleSpeechViewModel.recordingsDirectory.appendingPathComponent(fileName)
    }
    
    func transcribeExistingRecording(_ recording: Recording) async {
        guard !isProcessing else { return }
        
        processingRecordingIds.insert(recording.id)
        self.isProcessing = true
        transcriptionTask = Task {
            await processAudioFile(
                recordingURL: recording.fileURL,
                transcriptionURL: recording.fileURL,
                recordingId: recording.id,
                startDate: recording.startDate,
                duration: recording.duration ?? 0,
                processedDuration: recording.processedDuration,
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
        processedDuration: TimeInterval?,
        isExisting: Bool = false
    ) async {
        var cleanupURLs: [URL] = []
        defer {
            self.isProcessing = false
            self.transcriptionTask = nil
            processingRecordingIds.remove(recordingId)
            if !isExisting {
                self.currentRecordingId = nil
                self.currentRecordingStartDate = nil
            }
            for cleanupURL in cleanupURLs {
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
        
        let recordingURLToSave = ensureRecordingFile(
            for: recordingURL,
            processedURL: transcriptionURLToUse,
            preferProcessed: !isExisting
        )
        var transcriptionParts = [transcriptionURLToUse]
        do {
            transcriptionParts = try await AudioProcessor.shared.splitAudioIfNeeded(
                at: transcriptionURLToUse,
                maxSizeBytes: Constants.SimpleSpeech.maxAudioPayloadBytes
            )
        } catch {
            #if DEBUG
            print("SimpleSpeechViewModel: Audio splitting failed: \(error). Using original file.")
            #endif
        }

        var cleanupSet = Set<URL>()
        if transcriptionURLToUse != recordingURL, isTemporaryFile(transcriptionURLToUse) {
            cleanupSet.insert(transcriptionURLToUse)
        }
        for partURL in transcriptionParts where partURL != recordingURL && isTemporaryFile(partURL) {
            cleanupSet.insert(partURL)
        }
        cleanupURLs = Array(cleanupSet)
        
        var finalTranscription: String?
        
        do {
            #if DEBUG
            print("SimpleSpeechViewModel: Starting transcription for file: \(transcriptionURLToUse.lastPathComponent)")
            #endif
            var partResults: [String] = []
            for (index, partURL) in transcriptionParts.enumerated() {
                if Task.isCancelled { return }
                #if DEBUG
                print("SimpleSpeechViewModel: Transcribing part \(index + 1) of \(transcriptionParts.count)")
                #endif
                let partResult = try await simpleSpeechService.transcribe(audioFileURL: partURL)
                let trimmed = partResult.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    partResults.append(trimmed)
                }
            }
            var result = partResults.joined(separator: " ")
            
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
                let newRecording = Recording(
                    id: recordingId,
                    startDate: startDate,
                    relativeFilePath: recordingURLToSave.lastPathComponent,
                    duration: duration,
                    processedDuration: processedDuration,
                    transcription: finalTranscription
                )
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
        processingRecordingIds.removeAll()
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
        var previousItems: [PasteboardSnapshotItem] = []
        
        if canPaste && !shouldCopy {
            previousItems = snapshotPasteboardItems(from: pasteboard)
        }
        
        pasteboard.clearContents()
        pasteboard.setString(transcription, forType: .string)
        
        if canPaste {
            pasteClipboardIntoActiveApp()
        }
        
        if !shouldCopy {
            // Wait a tiny bit for the OS to process the paste event before clearing/restoring the clipper
            try? await Task.sleep(nanoseconds: Constants.UI.clipboardRestoreDelayNanoseconds) // 200ms
            
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                restorePasteboardItems(previousItems, to: pasteboard)
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

    private struct PasteboardSnapshotItem {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private func snapshotPasteboardItems(from pasteboard: NSPasteboard) -> [PasteboardSnapshotItem] {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return [] }
        return items.compactMap { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return dataByType.isEmpty ? nil : PasteboardSnapshotItem(dataByType: dataByType)
        }
    }

    private func restorePasteboardItems(_ items: [PasteboardSnapshotItem], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        let restoredItems = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
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
    
    private func ensureRecordingFile(
        for recordingURL: URL,
        processedURL: URL,
        preferProcessed: Bool
    ) -> URL? {
        if preferProcessed {
            if recordingURL == processedURL, isAudioFileUsable(recordingURL) {
                return recordingURL
            }
            if let savedURL = copyProcessedRecording(
                recordingURL: recordingURL,
                processedURL: processedURL,
                removeOriginal: true
            ) {
                return savedURL
            }
        }

        if isAudioFileUsable(recordingURL) {
            return recordingURL
        }

        if recordingURL == processedURL, isAudioFileUsable(recordingURL) {
            return recordingURL
        }

        return copyProcessedRecording(
            recordingURL: recordingURL,
            processedURL: processedURL,
            removeOriginal: false
        )
    }

    private func copyProcessedRecording(
        recordingURL: URL,
        processedURL: URL,
        removeOriginal: Bool
    ) -> URL? {
        guard recordingURL != processedURL, isAudioFileUsable(processedURL) else { return nil }

        let targetURL = recordingURLForProcessed(recordingURL: recordingURL, processedURL: processedURL)

        do {
            let directory = targetURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: processedURL, to: targetURL)
            if removeOriginal, targetURL != recordingURL, FileManager.default.fileExists(atPath: recordingURL.path) {
                try? FileManager.default.removeItem(at: recordingURL)
            }
            return isAudioFileUsable(targetURL) ? targetURL : nil
        } catch {
            #if DEBUG
            print("SimpleSpeechViewModel: Failed to save recording file: \(error)")
            #endif
            return nil
        }
    }

    private func recordingURLForProcessed(recordingURL: URL, processedURL: URL) -> URL {
        let processedExtension = processedURL.pathExtension
        guard !processedExtension.isEmpty,
              recordingURL.pathExtension.lowercased() != processedExtension.lowercased() else {
            return recordingURL
        }

        return recordingURL.deletingPathExtension().appendingPathExtension(processedExtension)
    }
    
    private func isTemporaryFile(_ url: URL) -> Bool {
        url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
    }
}
