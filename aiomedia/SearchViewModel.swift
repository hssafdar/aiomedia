import SwiftUI
import Combine

enum SearchService: String, CaseIterable {
    case torrents = "Torrents"
    case soulseek = "Soulseek"
}

enum SortOption: String, CaseIterable {
    case bestSeed = "Seeds"
    case recent = "Date"
    case size = "Size"
}

struct ProviderStatusInfo: Identifiable, Codable {
    var id: String { name }
    let name: String
    var isEnabled: Bool
}

class SearchViewModel: ObservableObject {
    static let shared = SearchViewModel()
    
    // UI State
    @Published var query = ""
    @Published var results: [SearchResult] = []
    @Published var isSearching = false
    @Published var totalResultsFound = 0
    @Published var favorites: [SearchResult] = []
    
    // Configuration
    @Published var selectedService: SearchService = .torrents
    @Published var sortOption: SortOption = .bestSeed
    @Published var providerSettings: [ProviderStatusInfo] = []
    
    // Soulseek Credentials
    @AppStorage("slsk_user") var slskUser: String = ""
    @AppStorage("slsk_pass") var slskPass: String = ""
    @Published var slskResults: [String] = []
    
    private let historyKey = "SearchHistory"
    private let providerKey = "ProviderSettings"
    private let favoritesKey = "SavedFavorites"
    @Published var searchHistory: [String] = []
    
    private var slskCancellable: AnyCancellable?
    
    init() {
        loadHistory()
        loadProviderSettings()
        loadFavorites()
        
        // Ensure File System exists
        _ = FileSystemManager.shared
        
        // --- 1. THIS IS THE NEW PART ---
        // Listen for incoming Soulseek results
        slskCancellable = SoulseekClient.shared.searchResultsSubject
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] newResults in
                guard let self = self, self.selectedService == .soulseek else { return }
                
                // Add results as they arrive
                self.results.append(contentsOf: newResults)
                self.totalResultsFound = self.results.count
                
                // Stop the loading spinner as soon as we get at least one result
                if !newResults.isEmpty {
                    self.isSearching = false
                }
            }
        // -------------------------------
    }
    
    // MARK: - Search Logic
    func performSearch() {
        guard !query.isEmpty else { return }
        addToHistory(query)
        
        if selectedService == .soulseek {
            performSoulseekSearch()
        } else {
            performTorrentSearch()
        }
    }
    
    private func performTorrentSearch() {
        isSearching = true
        results = []
        totalResultsFound = 0
        
        Task {
            let allProviders = SearchProviderManager.shared.allProviders
            
            await withTaskGroup(of: [SearchResult].self) { group in
                for provider in allProviders {
                    // Check if enabled (and skip Soulseek here, handled separately)
                    guard isProviderEnabled(provider.name), provider.name != "Soulseek" else { continue }
                    
                    group.addTask {
                        do {
                            return try await provider.search(query: self.query)
                        } catch {
                            return []
                        }
                    }
                }
                
                for await providerResults in group {
                    await MainActor.run {
                        self.results.append(contentsOf: providerResults)
                        self.applySort()
                        self.totalResultsFound = self.results.count
                    }
                }
            }
            
            await MainActor.run {
                self.isSearching = false
            }
        }
    }
    
    // --- 2. THIS IS THE FIXED FUNCTION ---
    private func performSoulseekSearch() {
        // Ensure logged in
        guard SoulseekClient.shared.isLoggedIn else { return }
        
        isSearching = true
        results = [] // Clear old results
        totalResultsFound = 0
        
        // Send the search packet (Results will come in via the listener in init)
        SoulseekClient.shared.search(query: query)
        
        // Optional: Timeout to stop spinner if no results after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.isSearching == true && self?.results.isEmpty == true {
                self?.isSearching = false
            }
        }
    }
    // -------------------------------------
    
    // MARK: - Sorting & Management
    func applySort() {
        switch sortOption {
        case .bestSeed:
            results.sort { $0.seeders > $1.seeders }
        case .recent:
            results.sort { ($0.pubDate ?? Date.distantPast) > ($1.pubDate ?? Date.distantPast) }
        case .size:
            results.sort { $0.size.localizedStandardCompare($1.size) == .orderedAscending }
        }
    }
    
    func isProviderEnabled(_ name: String) -> Bool {
        return providerSettings.first(where: { $0.name == name })?.isEnabled ?? false
    }
    
    func toggleProvider(_ name: String) {
        if let index = providerSettings.firstIndex(where: { $0.name == name }) {
            providerSettings[index].isEnabled.toggle()
            saveProviderSettings()
        }
    }
    
    // MARK: - Favorites Logic
    func isFavorite(_ item: SearchResult) -> Bool {
        favorites.contains(where: { $0.magnetLink == item.magnetLink })
    }
    
    func toggleFavorite(_ item: SearchResult) {
        if let index = favorites.firstIndex(where: { $0.magnetLink == item.magnetLink }) {
            favorites.remove(at: index)
        } else {
            favorites.append(item)
        }
        saveFavorites()
    }
    
    private func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: favoritesKey),
           let saved = try? JSONDecoder().decode([SearchResult].self, from: data) {
            favorites = saved
        }
    }
    
    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: favoritesKey)
        }
    }
    
    // MARK: - Persistence
    private func loadProviderSettings() {
        if let data = UserDefaults.standard.data(forKey: providerKey),
           let saved = try? JSONDecoder().decode([ProviderStatusInfo].self, from: data) {
            self.providerSettings = saved
        } else {
            let defaults = ["TPB", "1337x", "RuTor"]
            let allNames = SearchProviderManager.shared.allProviders.map { $0.name }
            self.providerSettings = allNames.map { name in
                ProviderStatusInfo(name: name, isEnabled: defaults.contains(name))
            }
        }
    }
    
    private func saveProviderSettings() {
        if let data = try? JSONEncoder().encode(providerSettings) {
            UserDefaults.standard.set(data, forKey: providerKey)
        }
    }
    
    private func loadHistory() {
        searchHistory = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }
    
    private func addToHistory(_ term: String) {
        if let index = searchHistory.firstIndex(of: term) { searchHistory.remove(at: index) }
        searchHistory.insert(term, at: 0)
        if searchHistory.count > 20 { searchHistory.removeLast() }
        UserDefaults.standard.set(searchHistory, forKey: historyKey)
    }
}
