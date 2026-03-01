# VocalRemoverCLI

A command-line tool that removes vocals from stereo audio files using phase-cancellation (mid/side processing).

## How it works

Lead vocals are almost always panned to the **centre** of a stereo mix, meaning they appear equally in the left and right channels.  
By computing the **side signal** — `(L − R) / 2` — the centred vocal content is cancelled while panned instruments are preserved:

```
left_out  =  (L − R) / 2
right_out = −(L − R) / 2
```

## Requirements

- macOS 12 or later (Xcode / Swift toolchain)
- A **16-bit stereo PCM WAV** input file

## Build

```bash
cd VocalRemoverCLI
swift build -c release
```

The binary is placed at `.build/release/VocalRemoverCLI`.

## Usage

```bash
# Using swift run (no separate build step required)
swift run VocalRemoverCLI <input.wav> <output.wav>

# Using the compiled binary
.build/release/VocalRemoverCLI song.wav instrumental.wav
```

### Non-WAV formats (MP3, AAC, M4A, FLAC, …)

Convert to WAV first with [ffmpeg](https://ffmpeg.org), then process:

```bash
ffmpeg -i song.mp3 song.wav
.build/release/VocalRemoverCLI song.wav instrumental.wav
```

## Example output

```
vocal-remover
  Input : song.wav
  Output: instrumental.wav
  45%
✓ Done. Saved to: instrumental.wav
```

## Limitations

- Input must be **stereo** (mono recordings cannot be processed).
- Only **16-bit PCM WAV** is accepted directly. Use ffmpeg for other formats.
- Results vary by recording. Best on well-produced studio tracks where  
  vocals are panned centre and instruments are spread across the stereo field.
- Background vocals, doubled harmonics, and reverb tails panned off-centre  
  will not be fully removed.

## In-app version

The same algorithm is also available inside the **aiomedia** iOS app under the **Vocal Remover** tab, where you can pick a file from your device and process it without a computer.
