
import Foundation
import CoreGraphics

struct Constants {
    struct Audio {
        static let silenceThresholdDb: Float = -35.0
        static let minSilenceDuration: TimeInterval = 1.0
        static let silencePadding: TimeInterval = 0.5
        static let resumePadding: TimeInterval = 0.5
        static let maxSplitBacktrack: TimeInterval = 30.0
        static let minSegmentDuration: TimeInterval = 0.5
        
        static let sampleRate: Double = 44100.0
        static let bitRate: Int = 64000
        static let channelCount: Int = 1
        
        static let minRecordingDuration: TimeInterval = 2.0
    }
    
    struct SimpleSpeech {
        static let maxAudioPayloadBytes: Int64 = 5_000 * 1024
        static let transcriptionRequestTimeout: TimeInterval = 300.0
        static let transcriptionResourceTimeout: TimeInterval = 1200.0
    }
    
    struct UI {
        static let mouseIndicatorDotSize: CGFloat = 10.0
        static let mouseIndicatorDotOffset = CGPoint(x: 15, y: -15)
        
        static let statusItemDotSize: CGFloat = 11.0
        static let statusItemDotYOffset: CGFloat = 9.0
        static let statusIconSize: CGFloat = 22.0
        
        static let timerInterval: TimeInterval = 1.0
        static let flashTimerInterval: TimeInterval = 0.5
        static let clipboardRestoreDelayNanoseconds: UInt64 = 200 * 1_000_000
    }
    
    struct Keyboard {
        static let rightCommandKeyCode: UInt16 = 54
        static let pttDelay: TimeInterval = 0.5
    }
}
