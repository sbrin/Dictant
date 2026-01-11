//
//  AudioProcessor.swift
//  Dictant
//
//  Created by Assistant.
//

import Foundation
import AVFoundation

/// Handles audio post-processing, specifically removing long periods of silence.
class AudioProcessor {
    static let shared = AudioProcessor()
    
    // MARK: - Configuration
    
    /// The threshold in decibels below which audio is considered "silence".
    private let silenceThresholdDb: Float = -35.0
    
    /// The minimum duration of silence (in seconds) that we want to remove.
    /// Pauses longer than this will be shortened.
    private let minSilenceDuration: TimeInterval = 1.0
    
    /// Amount of silence (in seconds) to keep when a long pause is detected.
    /// This prevents the audio from sounding unnatural/choppy by leaving a small gap.
    private let silencePadding: TimeInterval = 0.5

    /// Additional padding (in seconds) to keep before returning from a long pause.
    /// This helps preserve quiet speech that starts below the silence threshold.
    private let resumePadding: TimeInterval = 0.5

    private let maxSplitBacktrack: TimeInterval = 30.0
    
    private init() {}
    
    // MARK: - Public API
    
    /// Processes the audio file at the given URL to remove long silences.
    /// - Parameter inputURL: The URL of the source audio file.
    /// - Returns: A URL to the processed (trimmed) audio file, or the original URL if processing fails or isn't needed.
    func processAudio(at inputURL: URL) async throws -> URL {
        // 1. Setup Input
        let asset = AVAsset(url: inputURL)
        
        // Load the tracks asynchronously
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw AudioProcessorError.noAudioTrack
        }

        // Check duration - skip if less than 1 second
        let duration = try await asset.load(.duration).seconds
        if duration < 1.0 {
            return inputURL
        }
        
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        reader.add(trackOutput)

        // 2. Setup Output
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a") // Keep m4a container
            
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        
        // Use AAC for output to keep file size small (matches input format usually)
        var channelLayout = AudioChannelLayout()
        memset(&channelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        channelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        
        let writerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
            AVChannelLayoutKey: Data(bytes: &channelLayout, count: MemoryLayout<AudioChannelLayout>.size)
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerOutputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)
        
        // 3. Start Processing
        guard reader.startReading() else {
            throw AudioProcessorError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }
        
        guard writer.startWriting() else {
            throw AudioProcessorError.writerFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
        
        writer.startSession(atSourceTime: .zero)
        
        // 4. Processing Loop
        // We will read buffers, measure loudness, and write only the non-excessive-silence parts.
        // We need to re-timestamp samples so the gap closes.
        
        let success = await processSamples(
            reader: reader,
            output: trackOutput,
            writer: writer,
            writerInput: writerInput
        )
        
        if success {
            await writer.finishWriting()
            if writer.status != .completed {
                try? FileManager.default.removeItem(at: outputURL)
                throw AudioProcessorError.writerFailed(writer.error?.localizedDescription ?? "Unknown error")
            }
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                throw AudioProcessorError.processingFailed
            }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
               let size = attributes[.size] as? NSNumber,
               size.int64Value <= 0 {
                try? FileManager.default.removeItem(at: outputURL)
                throw AudioProcessorError.processingFailed
            }
            // Clean up original file if needed, but for now we return the new one
            // The caller can decide to delete the old one.
            return outputURL
        } else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioProcessorError.processingFailed
        }
    }

    /// Splits the audio file into two segments if it exceeds the given size limit.
    /// - Returns: A list of segment URLs in order. Returns the original URL when no split is needed.
    func splitAudioIfNeeded(at inputURL: URL, maxSizeBytes: Int64) async throws -> [URL] {
        guard maxSizeBytes > 0,
              let fileSize = fileSizeBytes(for: inputURL),
              fileSize > maxSizeBytes else {
            return [inputURL]
        }

        let asset = AVAsset(url: inputURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        let minSegmentDuration: Double = 1.0
        guard durationSeconds.isFinite, durationSeconds > minSegmentDuration * 2 else {
            return [inputURL]
        }

        let bytesPerSecond = Double(fileSize) / durationSeconds
        guard bytesPerSecond > 0 else {
            return [inputURL]
        }

        var targetSeconds = Double(maxSizeBytes) / bytesPerSecond
        let maxSplitSeconds = durationSeconds - minSegmentDuration
        targetSeconds = min(max(targetSeconds, minSegmentDuration), maxSplitSeconds)

        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        let candidateTime = try await findSilenceSplitTime(asset: asset, targetTime: targetTime)
        let rawCandidateSeconds = candidateTime?.seconds ?? targetSeconds
        let candidateSeconds = rawCandidateSeconds.isFinite ? rawCandidateSeconds : targetSeconds
        let splitSeconds = min(max(candidateSeconds, minSegmentDuration), maxSplitSeconds)
        let splitTime = CMTime(seconds: splitSeconds, preferredTimescale: 600)

        #if DEBUG
        let splitSource = candidateTime == nil ? "target" : "silence"
        print(String(format: "AudioProcessor: Splitting at %.2fs (%@).", splitSeconds, splitSource))
        #endif

        let firstRange = CMTimeRange(start: .zero, duration: splitTime)
        let secondRange = CMTimeRange(
            start: splitTime,
            duration: CMTime(seconds: durationSeconds - splitSeconds, preferredTimescale: 600)
        )

        let firstURL = try await exportSegment(asset: asset, timeRange: firstRange)
        let secondURL = try await exportSegment(asset: asset, timeRange: secondRange)

        return [firstURL, secondURL]
    }
    
    // MARK: - Private Processing Logic
    
    private func processSamples(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput
    ) async -> Bool {
        
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.dictant.audioprocessing")
            
            // State for silence detection
            var isSilentSequence = false
            var silenceStartTime: CMTime = .invalid
            var lastWrittenTime: CMTime = .zero
            var outputTimeOffset: CMTime = .invalid
            var didFinish = false
            
            // Pending silent buffers that we might write if the silence isn't long enough
            var pendingBuffers: [(CMSampleBuffer, CMTime)] = [] // (buffer, originalPTS)
            var trailingSilenceBuffers: [(CMSampleBuffer, CMTime)] = [] // (buffer, originalPTS)
            var trailingSilenceDuration: CMTime = .zero
            
            // Output buffering to handle backpressure
            var outgoingBuffers: [CMSampleBuffer] = []
            
            func finish(_ success: Bool) {
                guard !didFinish else { return }
                didFinish = true
                writerInput.markAsFinished()
                continuation.resume(returning: success)
            }
            
            /// Writes as many buffers from `outgoingBuffers` as possible.
            /// Returns `true` if we can continue generating data (buffer isn't full), `false` if we should stop and wait.
            func flushOutgoing() -> Bool {
                while !outgoingBuffers.isEmpty {
                    if writerInput.isReadyForMoreMediaData {
                        let buffer = outgoingBuffers.removeFirst()
                        if !writerInput.append(buffer) {
                            return false
                        }
                    } else {
                        // Not ready, stop writing and wait for next callback
                        return false
                    }
                }
                return true
            }

            func enqueueBuffer(_ buffer: CMSampleBuffer, originalPts: CMTime) {
                let offset = outputTimeOffset == .invalid ? originalPts : outputTimeOffset
                if outputTimeOffset == .invalid { outputTimeOffset = originalPts }

                let newPts = CMTimeSubtract(originalPts, offset)
                if let newBuffer = self.copyBufferWithNewPTS(buffer, newPts: newPts) {
                    outgoingBuffers.append(newBuffer)
                    lastWrittenTime = CMTimeAdd(newPts, CMSampleBufferGetDuration(buffer))
                }
            }

            func appendTrailingBuffer(_ buffer: CMSampleBuffer, pts: CMTime, maxDuration: CMTime) {
                trailingSilenceBuffers.append((buffer, pts))
                let bufferDuration = CMSampleBufferGetDuration(buffer)
                let safeDuration = bufferDuration.isValid ? bufferDuration : .zero
                trailingSilenceDuration = CMTimeAdd(trailingSilenceDuration, safeDuration)

                while CMTimeCompare(trailingSilenceDuration, maxDuration) == 1, !trailingSilenceBuffers.isEmpty {
                    let removed = trailingSilenceBuffers.removeFirst()
                    let removedDuration = CMSampleBufferGetDuration(removed.0)
                    let safeRemovedDuration = removedDuration.isValid ? removedDuration : .zero
                    trailingSilenceDuration = CMTimeSubtract(trailingSilenceDuration, safeRemovedDuration)
                }
            }
            
            writerInput.requestMediaDataWhenReady(on: queue) {
                if didFinish {
                    return
                }
                if Task.isCancelled || reader.status == .failed || reader.status == .cancelled || writer.status == .failed || writer.status == .cancelled {
                    finish(false)
                    return
                }
                // 1. Flush any pending data from previous runs
                if !flushOutgoing() {
                    if writer.status == .failed || writer.status == .cancelled {
                        finish(false)
                    }
                    return // Still not ready, wait for next callback
                }
                
                // 2. Generate new data as long as input is ready
                while writerInput.isReadyForMoreMediaData {
                    if Task.isCancelled || reader.status == .failed || reader.status == .cancelled || writer.status == .failed || writer.status == .cancelled {
                        finish(false)
                        return
                    }
                    guard let buffer = output.copyNextSampleBuffer() else {
                        // EOF - Handle potential pending silence
                        if isSilentSequence {
                            let silenceDuration = CMTimeGetSeconds(CMTimeSubtract(lastWrittenTime.isValid ? lastWrittenTime : silenceStartTime, silenceStartTime))
                            let pendingDuration = pendingBuffers.reduce(0.0) { $0 + CMSampleBufferGetDuration($1.0).seconds }
                             
                            if pendingDuration > self.minSilenceDuration {
                                // Trim end silence
                                let keepDuration = CMTime(seconds: self.silencePadding, preferredTimescale: 1000000)
                                var keptAccumulator = CMTime.zero
                                
                                for (pBuf, pPts) in pendingBuffers {
                                    if keptAccumulator < keepDuration {
                                        enqueueBuffer(pBuf, originalPts: pPts)
                                        keptAccumulator = CMTimeAdd(keptAccumulator, CMSampleBufferGetDuration(pBuf))
                                    }
                                }
                            } else {
                                // Short silence at end - keep all
                                for (pBuf, pPts) in pendingBuffers {
                                    enqueueBuffer(pBuf, originalPts: pPts)
                                }
                            }
                        }
                        
                        // flush remaining final buffers
                        _ = flushOutgoing()
                        
                        finish(reader.status == .completed && writer.status != .failed && writer.status != .cancelled)
                        return
                    }
                    
                    let pts = CMSampleBufferGetPresentationTimeStamp(buffer)

                    // analyze
                    let isSilent = self.isBufferSilent(buffer, thresholdDb: self.silenceThresholdDb)
                    
                    if isSilent {
                        if !isSilentSequence {
                            // Start of silence
                            isSilentSequence = true
                            silenceStartTime = pts
                        }
                        
                        // Optimization: If we already have enough silence buffered to cover the "keep" duration,
                        // we can stop buffering to save memory on long pauses.
                        let currentSilenceDuration = CMTimeGetSeconds(CMTimeSubtract(pts, silenceStartTime))
                        if currentSilenceDuration < self.minSilenceDuration {
                            pendingBuffers.append((buffer, pts))
                        }

                        let trailingDuration = CMTime(seconds: self.resumePadding, preferredTimescale: pts.timescale)
                        if self.resumePadding > 0 {
                            appendTrailingBuffer(buffer, pts: pts, maxDuration: trailingDuration)
                        }
                    } else {
                        // Not silent
                        if isSilentSequence {
                            // End of silence block
                            let silenceDuration = CMTimeGetSeconds(CMTimeSubtract(pts, silenceStartTime))
                            
                            if silenceDuration > self.minSilenceDuration {
                                // Long pause. We trim it.
                                // We keep the FIRST `silencePadding` and a small tail before audio resumes.
                                
                                let keepDuration = CMTime(seconds: self.silencePadding, preferredTimescale: pts.timescale)
                                var keptAccumulator = CMTime.zero
                                var leadingEndPts: CMTime?
                                
                                for (pBuf, pPts) in pendingBuffers {
                                    if keptAccumulator < keepDuration {
                                        // Write this silent buffer with offset
                                        enqueueBuffer(pBuf, originalPts: pPts)
                                        let bufferDuration = CMSampleBufferGetDuration(pBuf)
                                        keptAccumulator = CMTimeAdd(keptAccumulator, bufferDuration)
                                        leadingEndPts = CMTimeAdd(pPts, bufferDuration)
                                    }
                                }

                                var keptTrailingBuffers: [(CMSampleBuffer, CMTime)] = []
                                if self.resumePadding > 0 {
                                    for (tBuf, tPts) in trailingSilenceBuffers {
                                        if let leadingEndPts, leadingEndPts.isValid,
                                           CMTimeCompare(tPts, leadingEndPts) == -1 {
                                            continue
                                        }
                                        keptTrailingBuffers.append((tBuf, tPts))
                                    }
                                }

                                if let firstTrailing = keptTrailingBuffers.first {
                                    outputTimeOffset = CMTimeSubtract(firstTrailing.1, lastWrittenTime)
                                    for (tBuf, tPts) in keptTrailingBuffers {
                                        enqueueBuffer(tBuf, originalPts: tPts)
                                    }
                                }
                                
                                // Recalculate offset to close the gap
                                outputTimeOffset = CMTimeSubtract(pts, lastWrittenTime)
                                
                            } else {
                                // Short pause. Keep all.
                                for (pBuf, pPts) in pendingBuffers {
                                    enqueueBuffer(pBuf, originalPts: pPts)
                                }
                            }
                            
                            // Reset state
                            isSilentSequence = false
                            pendingBuffers.removeAll()
                            trailingSilenceBuffers.removeAll()
                            trailingSilenceDuration = .zero
                            silenceStartTime = .invalid
                        }
                        
                        // Write current non-silent buffer
                        enqueueBuffer(buffer, originalPts: pts)
                    }
                    
                    // Attempt to flush after each processing step
                    // If we can't flush everything, we break the loop (writerInput.isReadyForMoreMediaData will be checked next iteration or inside flushOutgoing)
                    if !flushOutgoing() {
                        if writer.status == .failed || writer.status == .cancelled {
                            finish(false)
                        }
                        break 
                    }
                }
            }
        }
    }
    
    private func isBufferSilent(_ buffer: CMSampleBuffer, thresholdDb: Float) -> Bool {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return true }
        
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let data = dataPointer else {
            return true
        }
        
        // Assuming 16-bit Int PCM
        let sampleCount = length / 2
        let samples = data.withMemoryRebound(to: Int16.self, capacity: sampleCount) { ptr in
            UnsafeBufferPointer(start: ptr, count: sampleCount)
        }
        
        var sumSquared: Float = 0
        // Optimization: check every Nth sample to speed up?
        // For accuracy, checking all is fine for now on Apple Silicon/modern Intel.
        for sample in samples {
            let floatSample = Float(sample) / Float(Int16.max)
            sumSquared += floatSample * floatSample
        }
        
        let rms = sqrt(sumSquared / Float(sampleCount))
        let db = rms > 0 ? 20 * log10(rms) : -100.0
        
        return db < thresholdDb
    }

    
    private func copyBufferWithNewPTS(_ buffer: CMSampleBuffer, newPts: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        
        var timingInfo = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(count))
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timingInfo, entriesNeededOut: nil)
        
        for i in 0..<timingInfo.count {
            timingInfo[i].decodeTimeStamp = .invalid // DTS is usually invalid for raw PCM or computed
            timingInfo[i].presentationTimeStamp = newPts
        }
        
        var newBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &newBuffer
        )
        return newBuffer
    }

    private func findSilenceSplitTime(asset: AVAsset, targetTime: CMTime) async throws -> CMTime? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw AudioProcessorError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        reader.add(trackOutput)
        reader.timeRange = CMTimeRange(start: .zero, duration: targetTime)

        guard reader.startReading() else {
            throw AudioProcessorError.readerFailed(reader.error?.localizedDescription ?? "Unknown error")
        }

        let minCandidateSeconds = max(targetTime.seconds - maxSplitBacktrack, 0)
        var lastCandidate: CMTime?
        var silenceStart: CMTime = .invalid
        var isSilentSequence = false

        while let buffer = trackOutput.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            let isSilent = self.isBufferSilent(buffer, thresholdDb: self.silenceThresholdDb)

            if isSilent {
                if !isSilentSequence {
                    isSilentSequence = true
                    silenceStart = pts
                }
            } else {
                if isSilentSequence && silenceStart.isValid {
                    let silenceDuration = CMTimeGetSeconds(CMTimeSubtract(pts, silenceStart))
                    if silenceDuration >= self.minSilenceDuration,
                       silenceStart.seconds >= minCandidateSeconds {
                        lastCandidate = silenceStart
                    }
                }
                isSilentSequence = false
                silenceStart = .invalid
            }
        }

        if isSilentSequence && silenceStart.isValid && silenceStart.seconds >= minCandidateSeconds {
            return silenceStart
        }

        return lastCandidate
    }

    private func exportSegment(asset: AVAsset, timeRange: CMTimeRange) async throws -> URL {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioProcessorError.exportFailed("Unable to create export session")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = timeRange
        exportSession.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume(returning: ())
            }
        }

        if exportSession.status == .completed,
           let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value > 0 {
            return outputURL
        }

        let errorMessage = exportSession.error?.localizedDescription ?? "Unknown error"
        throw AudioProcessorError.exportFailed(errorMessage)
    }

    private func fileSizeBytes(for url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }
}

enum AudioProcessorError: Error {
    case noAudioTrack
    case readerFailed(String)
    case writerFailed(String)
    case processingFailed
    case exportFailed(String)
}
