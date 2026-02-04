//
//  DownloadItem.swift
//  aiomedia
//
//  Created by Hamza S on 1/31/26.
//


import Foundation
import Combine
import ActivityKit // For Dynamic Island
import SwiftUI

// MARK: - Download Models
struct DownloadItem: Identifiable, Codable {
    var id = UUID()
    let fileName: String
    let username: String
    let size: Int64
    var progress: Double = 0.0
    var speed: String = "0 KB/s"
    var state: DownloadState = .queued
    var localURL: URL?
}

enum DownloadState: String, Codable {
    case queued = "Queued"
    case downloading = "Downloading"
    case paused = "Paused"
    case completed = "Completed"
    case failed = "Failed"
}

// MARK: - Download Manager
class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    
    @Published var downloads: [DownloadItem] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    
    // Live Activity (Dynamic Island)
    private var currentActivity: Any? // Type-erased Activity<DownloadAttributes>
    
    init() {
        // Load saved downloads (persistence)
        if let data = UserDefaults.standard.data(forKey: "saved_downloads"),
           let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            downloads = saved
        }
    }
    
    // MARK: - Actions
    func startDownload(item: SearchResult) {
        let newItem = DownloadItem(
            fileName: item.title,
            username: item.source == "Soulseek" ? "PeerUser" : "Torrent", // Simplified
            size: parseSize(item.size),
            state: .queued
        )
        
        DispatchQueue.main.async {
            self.downloads.insert(newItem, at: 0)
            self.save()
            self.processQueue()
        }
        
        // Start Live Activity
        startLiveActivity(itemName: newItem.fileName)
    }
    
    func pauseDownload(_ id: UUID) {
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index].state = .paused
            activeTasks[id]?.cancel()
            activeTasks[id] = nil
            save()
        }
    }
    
    func resumeDownload(_ id: UUID) {
        if let index = downloads.firstIndex(where: { $0.id == id }) {
            downloads[index].state = .queued
            save()
            processQueue()
        }
    }
    
    func removeDownload(_ indexSet: IndexSet) {
        for index in indexSet {
            let item = downloads[index]
            activeTasks[item.id]?.cancel()
            activeTasks[item.id] = nil
            
            // Delete file if exists
            if let url = item.localURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        downloads.remove(atOffsets: indexSet)
        save()
        endLiveActivity()
    }
    
    // MARK: - Internal Logic
    private func processQueue() {
        // Find next queued item
        guard let index = downloads.firstIndex(where: { $0.state == .queued }) else { return }
        let item = downloads[index]
        
        // Simulate Download (Replace with Real Soulseek TCP Logic later)
        downloads[index].state = .downloading
        
        let task = Task {
            var progress = item.progress
            while progress < 1.0 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s tick
                if Task.isCancelled { return }
                
                await MainActor.run {
                    // Update Progress
                    progress += 0.05
                    if let idx = self.downloads.firstIndex(where: { $0.id == item.id }) {
                        self.downloads[idx].progress = progress
                        self.downloads[idx].speed = "\(Int.random(in: 100...500)) KB/s"
                        
                        // Update Live Activity
                        self.updateLiveActivity(progress: progress)
                    }
                }
            }
            
            await MainActor.run {
                if let idx = self.downloads.firstIndex(where: { $0.id == item.id }) {
                    self.downloads[idx].state = .completed
                    self.downloads[idx].progress = 1.0
                    self.downloads[idx].speed = "Done"
                    self.save()
                    self.endLiveActivity()
                }
            }
        }
        activeTasks[item.id] = task
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(downloads) {
            UserDefaults.standard.set(data, forKey: "saved_downloads")
        }
    }
    
    private func parseSize(_ sizeStr: String) -> Int64 {
        // Very basic parser, improve as needed
        return 0 
    }
    
    // MARK: - Files App Helper
    func openDownloadsFolder() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        // The magic URL scheme to open Files app at specific path
        let sharedURL = documents.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
        if let url = URL(string: sharedURL) {
            UIApplication.shared.open(url)
        }
    }
    
    // MARK: - Live Activity Stubs
    // (Requires Widget Extension Target to function)
    private func startLiveActivity(itemName: String) {
        if #available(iOS 16.1, *) {
            // Attributes and Activity logic goes here
            // See Step 5 for the code you need to put in the Widget Extension
        }
    }
    
    private func updateLiveActivity(progress: Double) {
        if #available(iOS 16.1, *) {
            // Update logic
        }
    }
    
    private func endLiveActivity() {
        if #available(iOS 16.1, *) {
            // End logic
        }
    }
}
