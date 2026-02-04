import SwiftUI
import UIKit

struct DetailView: View {
    let item: SearchResult
    @ObservedObject private var viewModel = SearchViewModel.shared
    @State private var isCopied = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.title2.bold())
                    
                    HStack {
                        Text(item.source)
                            .font(.caption.bold())
                            .padding(4)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(4)
                        
                        Spacer()
                        
                        // Star Icon if favorited
                        if viewModel.isFavorite(item) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                                .font(.title3)
                        }
                    }
                }
                
                Divider()
                
                // Metadata Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                    MetaItem(title: "Size", value: item.size, icon: "internaldrive")
                    MetaItem(title: "Seeders", value: "\(item.seeders)", icon: "arrow.up.circle.fill", color: .green)
                    MetaItem(title: "Leechers", value: "\(item.leechers)", icon: "arrow.down.circle.fill", color: .red)
                    MetaItem(title: "Date", value: item.pubDate?.formatted(date: .long, time: .omitted) ?? "Unknown", icon: "calendar")
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                
                // Actions
                // ... inside DetailView ...

                                // Actions
                                VStack(spacing: 12) {
                                    
                                    // 1. Download Action
                                    Button(action: {
                                        DownloadManager.shared.startDownload(item: item)
                                        // Optional: Give haptic feedback
                                        let generator = UINotificationFeedbackGenerator()
                                        generator.notificationOccurred(.success)
                                    }) {
                                        Label("Download", systemImage: "arrow.down.circle.fill")
                                            .font(.headline)
                                            .foregroundColor(.white)
                                            .frame(maxWidth: .infinity)
                                            .padding()
                                            .background(Color.blue)
                                            .cornerRadius(12)
                                    }
                                    
                                    // ... Favorites and Copy Link buttons remain the same ...
                    
                    // 2. Favorite Toggle
                    Button(action: {
                        viewModel.toggleFavorite(item)
                    }) {
                        Label(
                            viewModel.isFavorite(item) ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: viewModel.isFavorite(item) ? "star.slash" : "star"
                        )
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    
                    // 3. Copy Link
                    Button(action: {
                        UIPasteboard.general.string = item.magnetLink
                        isCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
                    }) {
                        Label(isCopied ? "Copied!" : "Copy Magnet Link", systemImage: "doc.on.doc")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MetaItem: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .primary
    
    var body: some View {
        VStack(alignment: .leading) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
                .foregroundColor(color)
        }
    }
}
