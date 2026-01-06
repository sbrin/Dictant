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
    var transcription: String?
    
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
        guard let duration = duration else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: startDate)
    }
}
