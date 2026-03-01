//
//  VocalRemoverView.swift
//  aiomedia
//
//  Provides an in-app UI for removing vocals from a local audio file.
//

import SwiftUI
import UniformTypeIdentifiers

struct VocalRemoverView: View {

    @State private var inputURL:    URL?
    @State private var outputURL:   URL?
    @State private var isProcessing = false
    @State private var progress:    Double = 0
    @State private var resultMessage: String?
    @State private var showFilePicker = false
    @State private var errorMessage: String?

    private var inputFileName: String {
        inputURL?.lastPathComponent ?? "No file selected"
    }

    var body: some View {
        NavigationView {
            Form {
                // MARK: Input
                Section(header: Text("Input Audio")) {
                    HStack {
                        Text(inputFileName)
                            .foregroundColor(inputURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose") { showFilePicker = true }
                    }
                }

                // MARK: Process
                Section {
                    if isProcessing {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            Text("Processing… \(Int(progress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button(action: process) {
                            Label("Remove Vocals", systemImage: "waveform.slash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(inputURL == nil)
                    }
                }

                // MARK: Result
                if let message = resultMessage {
                    Section(header: Text("Result")) {
                        Text(message)
                            .foregroundColor(errorMessage == nil ? .green : .red)
                    }
                }

                // MARK: Info
                Section(header: Text("How it works")) {
                    Text("Vocals are typically panned to the centre of a stereo mix. " +
                         "This tool uses phase cancellation (mid/side processing) to " +
                         "isolate the side signal, which contains panned instruments " +
                         "while largely removing centred vocals.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Vocal Remover")
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    inputURL     = urls.first
                    resultMessage = nil
                    errorMessage  = nil
                case .failure(let error):
                    errorMessage  = error.localizedDescription
                    resultMessage = errorMessage
                }
            }
        }
    }

    // MARK: - Processing

    private func process() {
        guard let input = inputURL else { return }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseName = input.deletingPathExtension().lastPathComponent
        let output   = docs.appendingPathComponent("\(baseName)_instrumental.caf")

        isProcessing  = true
        progress      = 0
        resultMessage = nil
        errorMessage  = nil
        outputURL     = output

        Task.detached(priority: .userInitiated) {
            do {
                try VocalRemover.removeVocals(from: input, to: output) { p in
                    DispatchQueue.main.async { self.progress = p }
                }
                await MainActor.run {
                    isProcessing  = false
                    resultMessage = "Saved to: \(output.lastPathComponent)"
                    errorMessage  = nil
                }
            } catch {
                await MainActor.run {
                    isProcessing  = false
                    errorMessage  = error.localizedDescription
                    resultMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}
