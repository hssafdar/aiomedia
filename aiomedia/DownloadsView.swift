//
//  DownloadsView.swift
//  aiomedia
//
//  Created by Hamza S on 1/31/26.
//


import SwiftUI

struct DownloadsView: View {
    @StateObject private var manager = DownloadManager.shared
    
    var body: some View {
        NavigationView {
            List {
                if manager.downloads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.dotted")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("No Downloads")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .listRowSeparator(.hidden)
                    .padding(.top, 50)
                } else {
                    ForEach(manager.downloads) { item in
                        DownloadRow(item: item)
                    }
                    .onDelete { indexSet in
                        manager.removeDownload(indexSet)
                    }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { manager.openDownloadsFolder() }) {
                        Label("Files", systemImage: "folder.fill")
                    }
                }
            }
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.fileName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(item.state.rawValue)
                    .font(.caption)
                    .padding(4)
                    .background(statusColor(item.state).opacity(0.2))
                    .foregroundColor(statusColor(item.state))
                    .cornerRadius(4)
            }
            
            ProgressView(value: item.progress)
                .tint(statusColor(item.state))
            
            HStack {
                Text(item.username)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(item.speed)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.gray)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if item.state == .downloading || item.state == .queued {
                Button(action: { DownloadManager.shared.pauseDownload(item.id) }) {
                    Label("Pause", systemImage: "pause.circle")
                }
            } else if item.state == .paused {
                Button(action: { DownloadManager.shared.resumeDownload(item.id) }) {
                    Label("Resume", systemImage: "play.circle")
                }
            }
        }
    }
    
    func statusColor(_ state: DownloadState) -> Color {
        switch state {
        case .queued: return .gray
        case .downloading: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}