// VocalRemoverCLI — command-line vocal remover
//
// Removes vocals from a stereo 16-bit PCM WAV file using phase-cancellation
// (mid/side processing) and writes the instrumental result to a new WAV file.
//
// Usage:
//   swift run VocalRemoverCLI <input.wav> <output.wav>
//
// Build a stand-alone binary:
//   swift build -c release
//   .build/release/VocalRemoverCLI song.wav instrumental.wav
//
// For non-WAV formats (MP3, AAC, …) first convert with ffmpeg:
//   ffmpeg -i song.mp3 song.wav
//   .build/release/VocalRemoverCLI song.wav instrumental.wav

import Foundation

// MARK: - Error type

enum VocalRemoverError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case readError(String)
    case writeError(String)
    case unsupportedFormat(String)

    var description: String {
        switch self {
        case .fileNotFound(let p):      return "File not found: \(p)"
        case .readError(let m):         return "Read error: \(m)"
        case .writeError(let m):        return "Write error: \(m)"
        case .unsupportedFormat(let m): return "Unsupported format: \(m)"
        }
    }
}

// MARK: - WAV I/O helpers

/// Minimal WAV header (44 bytes, 16-bit PCM).
private struct WavHeader {
    var riff:          (UInt8, UInt8, UInt8, UInt8) = (82, 73, 70, 70) // "RIFF"
    var chunkSize:     UInt32 = 0
    var wave:          (UInt8, UInt8, UInt8, UInt8) = (87, 65, 86, 69) // "WAVE"
    var fmt:           (UInt8, UInt8, UInt8, UInt8) = (102, 109, 116, 32) // "fmt "
    var subchunk1Size: UInt32 = 16
    var audioFormat:   UInt16 = 1   // PCM
    var numChannels:   UInt16 = 2
    var sampleRate:    UInt32 = 44100
    var byteRate:      UInt32 = 0   // sampleRate * numChannels * bitsPerSample/8
    var blockAlign:    UInt16 = 0   // numChannels * bitsPerSample/8
    var bitsPerSample: UInt16 = 16
    var data:          (UInt8, UInt8, UInt8, UInt8) = (100, 97, 116, 97) // "data"
    var subchunk2Size: UInt32 = 0   // numSamples * numChannels * bitsPerSample/8
}

/// Reads a little-endian UInt16 from `data` at `offset`.
private func readLE16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

/// Reads a little-endian UInt32 from `data` at `offset`.
private func readLE32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset])       |
    (UInt32(data[offset + 1]) << 8)  |
    (UInt32(data[offset + 2]) << 16) |
    (UInt32(data[offset + 3]) << 24)
}

/// Appends a little-endian UInt16 to `data`.
private func appendLE16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
}

/// Appends a little-endian UInt32 to `data`.
private func appendLE32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
}

/// Appends a little-endian Int16 (as two unsigned bytes) to `data`.
private func appendLE16Sample(_ value: Int16, to data: inout Data) {
    let bits = UInt16(bitPattern: value)
    data.append(UInt8(bits & 0xFF))
    data.append(UInt8((bits >> 8) & 0xFF))
}

// MARK: - Core algorithm

/// Removes vocals from a 16-bit stereo PCM WAV file using phase cancellation.
///
/// The algorithm computes the "side" signal:
///   left_out  =  (L − R) / 2
///   right_out = −(L − R) / 2
///
/// Lead vocals are almost always panned to the centre so they appear equally
/// in both channels; L − R ≈ 0 cancels them, while panned instruments survive.
///
/// - Parameters:
///   - inputPath:  Path to the source WAV file.
///   - outputPath: Path where the processed WAV file will be written.
///   - onProgress: Optional closure receiving 0…1 progress values.
func removeVocals(inputPath: String,
                  outputPath: String,
                  onProgress: ((Double) -> Void)? = nil) throws {

    // ── Read input file ──────────────────────────────────────────────────
    guard FileManager.default.fileExists(atPath: inputPath) else {
        throw VocalRemoverError.fileNotFound(inputPath)
    }
    guard let fileData = FileManager.default.contents(atPath: inputPath) else {
        throw VocalRemoverError.readError("Could not read \(inputPath)")
    }
    guard fileData.count >= 44 else {
        throw VocalRemoverError.unsupportedFormat("File too small to be a valid WAV")
    }

    // ── Validate WAV header ──────────────────────────────────────────────
    let riffTag = String(bytes: fileData[0..<4], encoding: .ascii) ?? ""
    let waveTag = String(bytes: fileData[8..<12], encoding: .ascii) ?? ""
    guard riffTag == "RIFF", waveTag == "WAVE" else {
        throw VocalRemoverError.unsupportedFormat(
            "Not a WAV file. For MP3/AAC/M4A first convert with: ffmpeg -i input.mp3 input.wav")
    }

    // Parse fmt chunk (we expect it at offset 12)
    let fmtTag = String(bytes: fileData[12..<16], encoding: .ascii) ?? ""
    guard fmtTag == "fmt " else {
        throw VocalRemoverError.unsupportedFormat("Expected fmt chunk at offset 12")
    }
    let audioFormat  = readLE16(fileData, at: 20)
    let numChannels  = readLE16(fileData, at: 22)
    let sampleRate   = readLE32(fileData, at: 24)
    let bitsPerSample = readLE16(fileData, at: 34)

    guard audioFormat == 1 else {
        throw VocalRemoverError.unsupportedFormat(
            "Only uncompressed PCM WAV is supported (audioFormat=\(audioFormat))")
    }
    guard numChannels == 2 else {
        throw VocalRemoverError.unsupportedFormat(
            "Stereo input required (found \(numChannels) channel(s))")
    }
    guard bitsPerSample == 16 else {
        throw VocalRemoverError.unsupportedFormat(
            "Only 16-bit PCM is supported (found \(bitsPerSample)-bit)")
    }

    // Locate data chunk (scan past any extra fmt bytes or metadata chunks)
    var dataOffset = 12
    var dataSize: UInt32 = 0
    while dataOffset + 8 <= fileData.count {
        let tag = String(bytes: fileData[dataOffset..<(dataOffset + 4)], encoding: .ascii) ?? ""
        let chunkSize = readLE32(fileData, at: dataOffset + 4)
        if tag == "data" {
            dataSize   = chunkSize
            dataOffset += 8
            break
        }
        dataOffset += 8 + Int(chunkSize)
    }
    guard dataSize > 0, dataOffset + Int(dataSize) <= fileData.count else {
        throw VocalRemoverError.readError("Could not locate data chunk")
    }

    // ── Process samples ──────────────────────────────────────────────────
    // 16-bit stereo PCM: each frame = 4 bytes [L_lo, L_hi, R_lo, R_hi]
    let bytesPerFrame = 4
    let totalFrames   = Int(dataSize) / bytesPerFrame

    var outputSamples = Data(capacity: Int(dataSize))
    let clamp = { (v: Int32) -> Int16 in Int16(max(Int32(Int16.min), min(Int32(Int16.max), v))) }

    for i in 0..<totalFrames {
        let offset = dataOffset + i * bytesPerFrame

        let lRaw = Int16(bitPattern: UInt16(fileData[offset]) | (UInt16(fileData[offset + 1]) << 8))
        let rRaw = Int16(bitPattern: UInt16(fileData[offset + 2]) | (UInt16(fileData[offset + 3]) << 8))

        // side = (L − R) / 2  (integer arithmetic, arithmetic right-shift)
        let side = (Int32(lRaw) - Int32(rRaw)) / 2

        let lOut =  clamp(side)
        let rOut =  clamp(-side)

        appendLE16Sample(lOut, to: &outputSamples)
        appendLE16Sample(rOut, to: &outputSamples)

        // Report progress every 1 %
        if i % (max(1, totalFrames / 100)) == 0 {
            let pct = Double(i) / Double(totalFrames)
            onProgress?(pct)
        }
    }
    onProgress?(1.0)

    // ── Write output WAV ─────────────────────────────────────────────────
    var out = Data()
    out.reserveCapacity(44 + outputSamples.count)

    // RIFF header
    out.append(contentsOf: [82, 73, 70, 70])                            // "RIFF"
    appendLE32(UInt32(36 + outputSamples.count), to: &out)              // chunk size
    out.append(contentsOf: [87, 65, 86, 69])                            // "WAVE"

    // fmt chunk
    out.append(contentsOf: [102, 109, 116, 32])                         // "fmt "
    appendLE32(16, to: &out)                                             // subchunk1 size
    appendLE16(1, to: &out)                                              // PCM
    appendLE16(2, to: &out)                                              // 2 channels
    appendLE32(sampleRate, to: &out)
    appendLE32(sampleRate * 4, to: &out)                                 // byte rate
    appendLE16(4, to: &out)                                              // block align
    appendLE16(16, to: &out)                                             // bits per sample

    // data chunk
    out.append(contentsOf: [100, 97, 116, 97])                          // "data"
    appendLE32(UInt32(outputSamples.count), to: &out)
    out.append(outputSamples)

    guard FileManager.default.createFile(atPath: outputPath, contents: out) else {
        throw VocalRemoverError.writeError("Could not write to \(outputPath)")
    }
}

// MARK: - Entry point

func printUsage() {
    print("""
    vocal-remover — remove vocals from a stereo WAV audio file

    USAGE:
      swift run VocalRemoverCLI <input.wav> <output.wav>

    ARGUMENTS:
      <input.wav>   Path to a 16-bit stereo PCM WAV file
      <output.wav>  Destination path for the instrumental WAV file

    EXAMPLE:
      swift run VocalRemoverCLI song.wav instrumental.wav

    NON-WAV INPUT:
      Convert first with ffmpeg, then process:
        ffmpeg -i song.mp3 song.wav
        swift run VocalRemoverCLI song.wav instrumental.wav

    HOW IT WORKS:
      Lead vocals are almost always panned to the centre of a stereo mix,
      meaning they appear equally in the left and right channels.
      By computing the "side" signal  (L − R) / 2  the centred vocal
      content is cancelled while panned instruments are preserved.

    NOTE:
      Results vary by recording. Best results on well-produced studio tracks
      where vocals are panned centre and instruments are spread across the
      stereo field.
    """)
}

let args = CommandLine.arguments
guard args.count == 3 else {
    printUsage()
    exit(args.count == 1 ? 0 : 1)
}

let inputPath  = args[1]
let outputPath = args[2]

print("vocal-remover")
print("  Input : \((inputPath as NSString).lastPathComponent)")
print("  Output: \((outputPath as NSString).lastPathComponent)")

var lastPct = -5
do {
    try removeVocals(inputPath: inputPath, outputPath: outputPath) { pct in
        let p = Int(pct * 100)
        if p >= lastPct + 5 {
            lastPct = p
            print("  \(p)%", terminator: "\r")
            fflush(stdout)
        }
    }
    print("\n✓ Done. Saved to: \(outputPath)")
} catch {
    fputs("\nError: \(error)\n", stderr)
    exit(1)
}
