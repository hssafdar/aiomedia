//
//  VocalRemover.swift
//  aiomedia
//
//  Removes vocals from a stereo audio file using phase-cancellation (mid/side processing).
//  Vocals are typically centre-panned, so subtracting the left from the right channel
//  (the "side" signal) largely cancels them out.
//

import Foundation
import AVFoundation
import Accelerate

// MARK: - Error type

enum VocalRemoverError: LocalizedError {
    case fileNotFound
    case readFailed(String)
    case writeFailed(String)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .fileNotFound:       return "Input file not found."
        case .readFailed(let m):  return "Failed to read audio: \(m)"
        case .writeFailed(let m): return "Failed to write audio: \(m)"
        case .unsupportedFormat:  return "Unsupported audio format. Stereo input required."
        }
    }
}

// MARK: - Core processor

struct VocalRemover {

    /// Removes vocals from `inputURL` and writes the result to `outputURL`.
    ///
    /// The algorithm uses phase-cancellation (mid/side processing):
    ///   left_out  =  (L − R) / 2
    ///   right_out = −(L − R) / 2
    /// Because lead vocals are almost always panned to the centre they appear
    /// equally in both channels, so L − R ≈ 0 for vocal content.
    ///
    /// - Parameters:
    ///   - inputURL:  URL of the source stereo audio file (any format supported by AVFoundation).
    ///   - outputURL: URL where the processed file will be written (CAF format).
    ///   - progress:  Optional closure called with values in 0…1 as processing advances.
    static func removeVocals(from inputURL: URL,
                              to outputURL: URL,
                              progress: ((Double) -> Void)? = nil) throws {

        // ── Open the source file ───────────────────────────────────────────
        let srcFile: AVAudioFile
        do {
            srcFile = try AVAudioFile(forReading: inputURL)
        } catch {
            throw VocalRemoverError.readFailed(error.localizedDescription)
        }

        guard srcFile.processingFormat.channelCount == 2 else {
            throw VocalRemoverError.unsupportedFormat
        }

        let sampleRate   = srcFile.processingFormat.sampleRate
        let totalFrames  = AVAudioFrameCount(srcFile.length)

        // ── Create the output file (same sample-rate, stereo CAF) ─────────
        let outputSettings: [String: Any] = [
            AVFormatIDKey:            kAudioFormatLinearPCM,
            AVSampleRateKey:          sampleRate,
            AVNumberOfChannelsKey:    2,
            AVLinearPCMBitDepthKey:   32,
            AVLinearPCMIsFloatKey:    true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let dstFile: AVAudioFile
        do {
            dstFile = try AVAudioFile(forWriting: outputURL,
                                      settings: outputSettings)
        } catch {
            throw VocalRemoverError.writeFailed(error.localizedDescription)
        }

        // ── Process in chunks ─────────────────────────────────────────────
        let chunkSize: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(
                pcmFormat: srcFile.processingFormat,
                frameCapacity: chunkSize) else {
            throw VocalRemoverError.readFailed("Could not allocate PCM buffer")
        }

        var framesProcessed: AVAudioFrameCount = 0

        while framesProcessed < totalFrames {
            let framesToRead = min(chunkSize, totalFrames - framesProcessed)
            buffer.frameLength = framesToRead

            do {
                try srcFile.read(into: buffer, frameCount: framesToRead)
            } catch {
                throw VocalRemoverError.readFailed(error.localizedDescription)
            }

            // Interleaved float pointer: [L0, R0, L1, R1, …]
            guard let data = buffer.floatChannelData else {
                throw VocalRemoverError.readFailed("No float channel data")
            }

            let count = Int(framesToRead)
            let left  = data[0]   // pointer to left-channel samples
            let right = data[1]   // pointer to right-channel samples

            // side = (L − R) / 2
            var side = [Float](repeating: 0, count: count)
            vDSP_vsub(right, 1, left, 1, &side, 1, vDSP_Length(count))  // side = L - R
            var half: Float = 0.5
            vDSP_vsmul(side, 1, &half, &side, 1, vDSP_Length(count))    // side /= 2

            // Write side to left channel, negated side to right channel
            cblas_scopy(Int32(count), side, 1, left, 1)
            vDSP_vneg(side, 1, right, 1, vDSP_Length(count))

            do {
                try dstFile.write(from: buffer)
            } catch {
                throw VocalRemoverError.writeFailed(error.localizedDescription)
            }

            framesProcessed += framesToRead
            progress?(Double(framesProcessed) / Double(totalFrames))
        }
    }
}
