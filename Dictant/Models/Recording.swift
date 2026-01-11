//
//  Recording.swift
//  Dictant
//

import Foundation

/// Represents a single audio recording with metadata
struct Recording: Identifiable, Codable, Equatable {
    let id: UUID
    let startDate: Date
    let relativeFilePath: String // Store only the filename
    let duration: TimeInterval?
    let processedDuration: TimeInterval?
    var transcription: String?

    init(
        id: UUID,
        startDate: Date,
        relativeFilePath: String,
        duration: TimeInterval?,
        processedDuration: TimeInterval? = nil,
        transcription: String? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.relativeFilePath = relativeFilePath
        self.duration = duration
        self.processedDuration = processedDuration
        self.transcription = transcription
    }
    
    static func == (lhs: Recording, rhs: Recording) -> Bool {
        lhs.id == rhs.id
    }
    
    var fileURL: URL {
        SimpleSpeechViewModel.recordingsDirectory.appendingPathComponent(relativeFilePath)
    }
    
    var fileName: String {
        relativeFilePath
    }
    
    var formattedDuration: String {
        Self.formatDuration(duration)
    }

    var formattedProcessedDuration: String {
        Self.formatDuration(processedDuration)
    }
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: startDate)
    }

    private static func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
