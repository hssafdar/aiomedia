import SwiftUI
import UIKit

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel.shared
    @StateObject private var slskClient = SoulseekClient.shared
    @FocusState private var isFocused: Bool
    @State private var showConsole = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                
                // MARK: - Header
                VStack(spacing: 12) {
                    Picker("Service", selection: $viewModel.selectedService) {
                        ForEach(SearchService.allCases, id: \.self) { service in
                            Text(service.rawValue).tag(service)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    
                    // Search Bar
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundColor(.gray)
                        TextField("Search \(viewModel.selectedService.rawValue)...", text: $viewModel.query)
                            .focused($isFocused)
                            .submitLabel(.search)
                            .onSubmit { viewModel.performSearch() }
                        
                        if viewModel.isSearching {
                            ProgressView().scaleEffect(0.8)
                        } else if !viewModel.query.isEmpty {
                            Button(action: { viewModel.query = "" }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(.systemGray6))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    
                    // MARK: - Info Row (Live Counter + Console Button)
                    HStack {
                        // Live Result Counter
                        if viewModel.isSearching || !viewModel.results.isEmpty {
                            Text("\(viewModel.totalResultsFound) Results")
                                .font(.caption.bold())
                                .foregroundColor(.blue)
                                .transition(.scale.combined(with: .opacity))
                        }
                        
                        Spacer()
                        
                        // Console Button (Only for Soulseek)
                        if viewModel.selectedService == .soulseek {
                            Button(action: { showConsole.toggle() }) {
                                Label("Console", systemImage: "terminal")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.black)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .frame(height: 30) // Fixed height to prevent jumping
                }
                .padding(.bottom, 10)
                .background(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 5, y: 5)
                .zIndex(1)
                
                // MARK: - Content
                if viewModel.selectedService == .soulseek {
                    if !slskClient.isLoggedIn {
                        SoulseekLoginView()
                            .transition(.opacity)
                    } else {
                        // Logged In -> Show Results
                        List(viewModel.results) { item in
                            NavigationLink(destination: DetailView(item: item)) {
                                DetailedResultRow(item: item)
                            }
                        }
                        .listStyle(.plain)
                    }
                } else {
                    List(viewModel.results) { item in
                        NavigationLink(destination: DetailView(item: item)) {
                            DetailedResultRow(item: item)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showConsole) {
                ConsoleView()
                    .presentationDetents([.medium, .large])
            }
        }
        .onAppear {
            // Auto Login on App Launch
            if viewModel.selectedService == .soulseek {
                slskClient.autoConnect()
            }
        }
        .onChange(of: viewModel.selectedService) { service in
            if service == .soulseek {
                slskClient.autoConnect()
            }
        }
    }
}
