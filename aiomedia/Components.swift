//
//  DetailedResultRow.swift
//  aiomedia
//
//  Created by Hamza S on 1/28/26.
//


import SwiftUI

// A shared row design for search results
struct DetailedResultRow: View {
    let item: SearchResult
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundColor(.primary)
            
            HStack(spacing: 12) {
                // Size
                Label(item.size, systemImage: "internaldrive")
                    .foregroundColor(.secondary)
                
                // Seeds
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up")
                    Text("\(item.seeders)")
                }
                .foregroundColor(.green)
                
                // Source Tag
                Text(item.source)
                    .font(.caption2.bold())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
                
                Spacer()
                
                // Date (if available)
                if let date = item.pubDate {
                    Text(date.formatted(date: .numeric, time: .omitted))
                        .foregroundColor(.gray)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

// Simple Badge component
struct Badge: View {
    let text: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .foregroundColor(color)
        .cornerRadius(4)
    }
}

struct SoulseekLoginPlaceholder: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bird.fill")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("Soulseek Login Required")
                .font(.headline)
            Text("Please enter your credentials in Settings to search Soulseek.")
                .font(.caption)
                .foregroundColor(.gray)
            Spacer()
        }
    }
}