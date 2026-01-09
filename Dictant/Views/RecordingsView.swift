//
//  RecordingsView.swift
//  Dictant
//

import SwiftUI
import AppKit

struct RecordingsView: View {
    @StateObject private var speechViewModel = SimpleSpeechViewModel.shared
    @State private var expandedRecordingId: UUID?
    @State private var showingClearHistoryAlert = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                if !speechViewModel.recordings.isEmpty {
                    Button(role: .destructive) {
                        showingClearHistoryAlert = true
                    } label: {
                        Text("Clear History")
                    }
                    .buttonStyle(.borderless)
                }
            }
            
            if speechViewModel.recordings.isEmpty {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No recordings yet")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List {
                    ForEach(speechViewModel.recordings) { recording in
                        RecordingRow(
                            recording: recording,
                            isExpanded: expandedRecordingId == recording.id,
                            onToggle: { toggleExpansion(for: recording) }
                        )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(20)
        .alert("Clear History", isPresented:
                $showingClearHistoryAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear All", role: .destructive) {
                    speechViewModel.clearHistory()
                }
            } message: {
                Text("Are you sure you want to delete all recordings and history? This action cannot be undone.")
            }
    }
    
    private func toggleExpansion(for recording: Recording) {
        if expandedRecordingId == recording.id {
            expandedRecordingId = nil
        } else {
            expandedRecordingId = recording.id
        }
    }
}

struct RecordingRow: View {
    let recording: Recording
    let isExpanded: Bool
    let onToggle: () -> Void
    @StateObject private var speechViewModel = SimpleSpeechViewModel.shared
    
    private var isTranscribing: Bool {
        speechViewModel.processingRecordingIds.contains(recording.id)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(recording.formattedDate)
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                        .scaleEffect(0.7, anchor: .center)
                    Text(recording.formattedDuration)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(recording.transcription != nil ? "" : "•")
                        .foregroundColor(.secondary)
                    
                    Text(recording.transcription != nil ? "" : "Pending/Error")
                        .font(.caption)
                        .foregroundColor(recording.transcription != nil ? .green : .orange)
                }
                
                Spacer()
                
                if recording.transcription == nil || recording.transcription?.isEmpty == true {
                    Button {
                        Task {
                            await speechViewModel.transcribeExistingRecording(recording)
                        }
                    } label: {
                        Image(systemName: "waveform.badge.mic")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isTranscribing ? .secondary : .accentColor)
                    .disabled(isTranscribing)
                    .help(isTranscribing ? "Transcription in progress" : "Transcribe recording")
                }
                
                Button {
                    speechViewModel.copyTranscription(recording)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Copy transcription")
                .disabled(recording.transcription?.isEmpty ?? true)
                
                Button {
                    speechViewModel.showInFinder(recording)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Show in Finder")
                
                Button(role: .destructive) {
                    speechViewModel.deleteRecording(recording)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Delete recording")
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if isTranscribing {
                    NSCursor.arrow.set()
                    return
                }
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .onTapGesture {
                onToggle()
            }
            
            if isExpanded {
                if let transcription = recording.transcription, !transcription.isEmpty {
                    Text(transcription)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No transcription available")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
