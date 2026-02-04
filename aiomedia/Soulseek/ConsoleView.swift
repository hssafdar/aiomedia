//
//  ConsoleView.swift
//  aiomedia
//
//  Created by Hamza S on 1/31/26.
//


import SwiftUI

struct ConsoleView: View {
    @StateObject private var client = SoulseekClient.shared
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                // UPnP Status Bar
                HStack {
                    Text("Router: \(UPnPManager.shared.status)")
                        .font(.caption)
                        .foregroundColor(UPnPManager.shared.isMapped ? .green : .orange)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
                .background(Color.black)
                
                // Log List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(client.logs) { log in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(log.time.formatted(date: .omitted, time: .standard))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.gray)
                                    
                                    Text(log.message)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(colorForType(log.type))
                                        .multilineTextAlignment(.leading)
                                }
                                .id(log.id)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color.black)
                    .onChange(of: client.logs.count) { _ in
                        if let last = client.logs.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .navigationTitle("Console")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: copyLogsToClipboard) {
                        Image(systemName: "doc.on.doc")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        client.logs.removeAll()
                    }
                }
            }
        }
    }
    
    private func copyLogsToClipboard() {
        let logText = client.logs.map { log in
            "[\(log.time.formatted(date: .omitted, time: .standard))] \(log.message)"
        }.joined(separator: "\n")
        
        UIPasteboard.general.string = logText
    }
    
    private func colorForType(_ type: SoulseekClient.LogType) -> Color {
        switch type {
        case .info: return .white
        case .success: return .green
        case .error: return .red
        case .traffic: return .blue
        }
    }
}
