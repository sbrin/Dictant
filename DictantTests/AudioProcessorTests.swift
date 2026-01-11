//
//  AudioProcessorTests.swift
//  DictantTests
//
//  Created by Assistant.
//

import XCTest
import AVFoundation
@testable import Dictant

final class AudioProcessorTests: XCTestCase {

    var audioProcessor: AudioProcessor!
    
    override func setUpWithError() throws {
        audioProcessor = AudioProcessor.shared
    }

    override func tearDownWithError() throws {
        // cleanup code if needed
    }

    func testSilenceRemovalWithRealFile() async throws {
        // Locate the file in the test bundle or assuming path for now (user provided absolute path context)
        let inputPath = "/Users/sun/Library/Mobile Documents/com~apple~CloudDocs/Projects/telly-whisper/Dictant/DictantTests/silent-noise.m4a"
        let inputURL = URL(fileURLWithPath: inputPath)
        
        guard FileManager.default.fileExists(atPath: inputPath) else {
            print("Skipping test: silent-noise.m4a not found at \(inputPath)")
            return
        }
        
        let initialAsset = AVAsset(url: inputURL)
        let initialDuration = try await initialAsset.load(.duration).seconds
        print("Real File Duration: \(initialDuration)s")
        
        // Process
        print("Processing real audio...")
        let outputURL = try await audioProcessor.processAudio(at: inputURL)
        
        let finalAsset = AVAsset(url: outputURL)
        let finalDuration = try await finalAsset.load(.duration).seconds
        print("Processed Real File Duration: \(finalDuration)s")
        
        XCTAssertLessThan(finalDuration, initialDuration, "File duration should be reduced if it contains silence")
        // The file is 8.8s. If it is all silence/noise, it should be heavily reduced (e.g. to < 2s).
    }

    func testSilenceRemoval() async throws {
        // 1. Generate a test audio file with known silence
        let inputURL = try await generateTestFile()
        
        let initialAsset = AVAsset(url: inputURL)
        let initialDuration = try await initialAsset.load(.duration).seconds
        print("Test file generated. Duration: \(initialDuration)s")
        
        // 2. Process it
        print("Processing audio...")
        let outputURL = try await audioProcessor.processAudio(at: inputURL)
        
        // 3. Verify
        let finalAsset = AVAsset(url: outputURL)
        let finalDuration = try await finalAsset.load(.duration).seconds
        print("Processed file duration: \(finalDuration)s")
        
        // Logic check:
        // Input: 1s Sound + 4s Silence + 1s Sound = 6s.
        // Logic: >2s (now 1s from user edit) silence is trimmed, keeping 0.5s leading and trailing padding.
        // Expected: 1s + 0.5s + 0.5s + 1s = 3.0s.
        
        XCTAssertLessThan(finalDuration, initialDuration, "File duration should be reduced")
        XCTAssertGreaterThan(finalDuration, 1.5, "File should generally be around 2.5s")
        
        // Cleanup
        try? FileManager.default.removeItem(at: inputURL)
        try? FileManager.default.removeItem(at: outputURL)
    }
    
    func testShortAudioSkipped() async throws {
        // 1. Generate a short audio file (0.5s)
        let inputURL = try await generateTestFile(duration: 0.5)
        
        // 2. Process it
        print("Processing short audio...")
        let outputURL = try await audioProcessor.processAudio(at: inputURL)
        
        // 3. Verify
        XCTAssertEqual(inputURL, outputURL, "Short files should be returned as-is (skipped processing)")
        
        let asset = AVAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.1, "Duration should remain unchanged")
        
        // Cleanup
        try? FileManager.default.removeItem(at: inputURL)
    }

    // MARK: - Helpers
    
    private func generateTestFile(duration: Double = 6.0) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        // Create samples
        // If duration is short (e.g. 0.5), just write sound.
        // If default (6.0), use the complex silence pattern.
        
        let sampleRate = 44100.0
        let totalSeconds = duration

        let samplesPerBuffer = 1024
        
        var currentSample: Int64 = 0
        
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "generator")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if Double(currentSample) / sampleRate >= totalSeconds {
                        input.markAsFinished()
                        writer.finishWriting {
                            continuation.resume(returning: url)
                        }
                        return
                    }
                    
                    // Create buffer
                    var samples = [Int16]()
                    samples.reserveCapacity(samplesPerBuffer)
                    
                    for _ in 0..<samplesPerBuffer {
                        let time = Double(currentSample) / sampleRate
                        var value: Int16 = 0
                        
                        if time < 1.0 {
                            // Sound
                            value = Int16(sin(time * 440.0 * 2.0 * .pi) * 10000.0)
                        } else if time >= 1.0 && time < 5.0 {
                            // Silence (Long pause)
                            value = 0
                        } else {
                             // Sound
                            value = Int16(sin(time * 440.0 * 2.0 * .pi) * 10000.0)
                        }
                        samples.append(value)
                        currentSample += 1
                        
                        if Double(currentSample) / sampleRate >= totalSeconds { break }
                    }
                    
                    if let buffer = self.createPCMBuffer(from: samples, timestamp: CMTime(value: currentSample - Int64(samples.count), timescale: 44100)) {
                        input.append(buffer)
                    }
                }
            }
        }
    }
    
    private func createPCMBuffer(from samples: [Int16], timestamp: CMTime) -> CMSampleBuffer? {
        let bytes = samples.count * 2
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
        
        guard status == kCMBlockBufferNoErr, let filledBlockBuffer = blockBuffer else { return nil }
        
        samples.withUnsafeBufferPointer { ptr in
             status = CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: filledBlockBuffer, offsetIntoDestination: 0, dataLength: bytes)
        }
        
        guard status == kCMBlockBufferNoErr else { return nil }

        var desc: CMFormatDescription?
        var asbd = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: filledBlockBuffer, formatDescription: desc, sampleCount: samples.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
        
        return sampleBuffer
    }
}
