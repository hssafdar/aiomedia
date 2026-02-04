//
//  FileSystemManager.swift
//  aiomedia
//
//  Created by Hamza S on 1/28/26.
//


import Foundation

class FileSystemManager {
    static let shared = FileSystemManager()
    
    let torrentsDir: URL
    let soulseekDir: URL
    
    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        // Define paths
        self.torrentsDir = documents.appendingPathComponent("Torrents")
        self.soulseekDir = documents.appendingPathComponent("Soulseek")
        
        createDirectories()
    }
    
    private func createDirectories() {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: torrentsDir.path) {
                try fm.createDirectory(at: torrentsDir, withIntermediateDirectories: true)
                print("📁 Created Torrents Folder")
            }
            if !fm.fileExists(atPath: soulseekDir.path) {
                try fm.createDirectory(at: soulseekDir, withIntermediateDirectories: true)
                print("📁 Created Soulseek Folder")
            }
        } catch {
            print("FileSystem Error: \(error)")
        }
    }
    
    // Helper to save a magnet link as a file (optional future proofing)
    func saveMagnetFile(name: String, magnetLink: String) {
        let cleanName = name.components(separatedBy: .illegalCharacters).joined()
        let fileURL = torrentsDir.appendingPathComponent("\(cleanName).magnet")
        try? magnetLink.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}