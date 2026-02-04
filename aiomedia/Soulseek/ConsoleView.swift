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
        VStack(alignment: .leading, spacing: 0) {
            // Header
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
                                    .foregroundColor(color(for: log.type))
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
    }
    
    func color(for type: SoulseekClient.LogType) -> Color {
        switch type {
        case .info: return .white
        case .success: return .green
        case .error: return .red
        case .traffic: return .blue
        }
    }
}
